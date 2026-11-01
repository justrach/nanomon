//! The window's frame on Windows. nanoui makes windows with the system's
//! caption; nanomon's header is its title bar (as on macOS under a hidden
//! title bar), so that caption would sit above it as a second, empty bar.
//! This takes it away: the client area fills the whole window, the header
//! carries the window's buttons (kit.caption), and the empty part of the
//! header drags the window and maximizes it on a double-click, as the
//! caption did. The resize edges, the shadow, and Windows 11's rounded
//! corners stay.
const std = @import("std");

/// The width the window's three buttons take, in points.
pub const caption_w: f32 = 138;
/// How much of the header's right the page's controls take (the range's
/// segments and pause); the header left of that drags the window.
const controls_w: f32 = 210;

const HWND = *anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const MARGINS = extern struct { left: i32, right: i32, top: i32, bottom: i32 };
const MONITORINFO = extern struct {
    cb_size: u32 = @sizeOf(MONITORINFO),
    monitor: RECT = .{},
    work: RECT = .{},
    flags: u32 = 0,
};
const NCCALCSIZE_PARAMS = extern struct {
    /// The proposed client rects, the first kept.
    rgrc: [3]RECT,
    pos: ?*anyopaque,
};

const WM_NCCALCSIZE = 0x0083;
const WM_NCHITTEST = 0x0084;
const GWLP_WNDPROC = -4;
const SWP_NOSIZE = 0x0001;
const SWP_NOMOVE = 0x0002;
const SWP_NOZORDER = 0x0004;
const SWP_FRAMECHANGED = 0x0020;
const MONITOR_DEFAULTTONEAREST = 2;
/// Windows 11: the window's corners; `DWMWCP_ROUND` rounds them.
const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
const DWMWCP_ROUND = 2;

// What a hit test answers.
const ht_client = 1;
const ht_caption = 2;
const ht_left = 10;
const ht_right = 11;
const ht_top = 12;
const ht_top_left = 13;
const ht_top_right = 14;
const ht_bottom = 15;
const ht_bottom_left = 16;
const ht_bottom_right = 17;

extern "user32" fn GetWindowLongPtrW(h: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(h: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(prev: WNDPROC, h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetClientRect(h: HWND, r: *RECT) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(h: HWND, p: *POINT) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(h: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) i32;
extern "user32" fn IsZoomed(h: HWND) callconv(.winapi) i32;
extern "user32" fn GetDpiForWindow(h: HWND) callconv(.winapi) u32;
extern "user32" fn MonitorFromWindow(h: HWND, flags: u32) callconv(.winapi) ?HWND;
extern "user32" fn GetMonitorInfoW(m: HWND, info: *MONITORINFO) callconv(.winapi) i32;
extern "dwmapi" fn DwmExtendFrameIntoClientArea(h: HWND, margins: *const MARGINS) callconv(.winapi) i32;
extern "dwmapi" fn DwmSetWindowAttribute(h: HWND, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;

var prev_proc: WNDPROC = undefined;
var installed = false;

/// Removes the caption from the window `hwnd`, keeping the rest of its
/// frame; the header takes the caption's place.
pub fn install(hwnd: ?HWND) void {
    const h = hwnd orelse return;
    if (installed) return;
    installed = true;
    // A shadow round the window, and rounded corners where Windows 11 has
    // them (earlier versions ignore both).
    const margins: MARGINS = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 };
    _ = DwmExtendFrameIntoClientArea(h, &margins);
    var corners: u32 = DWMWCP_ROUND;
    _ = DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, @sizeOf(u32));
    const prev = SetWindowLongPtrW(h, GWLP_WNDPROC, @bitCast(@intFromPtr(&proc)));
    if (prev == 0) return;
    prev_proc = @ptrFromInt(@as(usize, @bitCast(prev)));
    // The frame is worked out again with the new procedure in place.
    _ = SetWindowPos(h, null, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);
}

fn proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        // The whole window is the client: no caption, no border drawn.
        WM_NCCALCSIZE => if (wp != 0) {
            if (IsZoomed(h) != 0) {
                // Maximized, the frame still counts: keep the client on
                // the monitor's work area, not under its edges.
                var info: MONITORINFO = .{};
                if (MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST)) |monitor| {
                    if (GetMonitorInfoW(monitor, &info) != 0)
                        (@as(*NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @bitCast(lp))))).rgrc[0] = info.work;
                }
            }
            return 0;
        },
        // The edges resize; the header is the caption, and its buttons
        // and the page's controls are the client's.
        WM_NCHITTEST => if (hitTest(h, lp)) |r| return r,
        else => {},
    }
    return CallWindowProcW(prev_proc, h, msg, wp, lp);
}

fn hitTest(h: HWND, lp: LPARAM) ?LRESULT {
    const bits: usize = @bitCast(lp);
    var p: POINT = .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
    if (ScreenToClient(h, &p) == 0) return null;
    var r: RECT = .{};
    if (GetClientRect(h, &r) == 0) return null;
    const s = scale(h);
    const edge: i32 = @intFromFloat(@max(2, 6 * s));
    const header: i32 = @intFromFloat(@import("view_kit.zig").header_h * s);
    const left = p.x < edge;
    const right = p.x >= r.right - edge;
    const top = p.y < edge;
    const bottom = p.y >= r.bottom - edge;
    if (top and left) return ht_top_left;
    if (top and right) return ht_top_right;
    if (bottom and left) return ht_bottom_left;
    if (bottom and right) return ht_bottom_right;
    if (left) return ht_left;
    if (right) return ht_right;
    if (top) return ht_top;
    if (bottom) return ht_bottom;
    // The header, less the window's buttons and the page's controls.
    const taken: i32 = @intFromFloat((caption_w + controls_w) * s);
    if (p.y < header and p.x < r.right - taken) return ht_caption;
    return null;
}

fn scale(h: HWND) f32 {
    const dpi = GetDpiForWindow(h);
    return if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
}
