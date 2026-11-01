//! Apps' icons in the table, as Activity Monitor shows them: the system's
//! icon for an app, drawn small and kept as PNG bytes for `ui.image` (macOS,
//! from NSWorkspace; Windows, from the program's own resources). Made on the
//! main thread, once a bundle, a few a frame so a first screenful does not
//! stall.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .windows;

/// New icons made in one frame at most; the rest come in the next ones.
pub const per_frame = 6;

/// The size an icon is made at, in pixels (32 points at 2×).
const icon_px = 32;

pub const Icons = struct {
    gpa: std.mem.Allocator,
    /// Bundle path → PNG bytes (empty when it has none). Keys are owned.
    made: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Made this frame, and whether some were left for the next.
    budget: u32 = per_frame,
    pending: bool = false,

    pub fn deinit(i: *Icons) void {
        var it = i.made.iterator();
        while (it.next()) |e| {
            i.gpa.free(e.key_ptr.*);
            i.gpa.free(e.value_ptr.*);
        }
        i.made.deinit(i.gpa);
    }

    /// At the start of a frame.
    pub fn frame(i: *Icons) void {
        i.budget = per_frame;
        i.pending = false;
    }

    /// The icon of the app at `bundle`, if it has one (and it is made).
    pub fn get(i: *Icons, bundle: []const u8) ?[]const u8 {
        if (comptime !supported) return null;
        if (bundle.len == 0) return null;
        if (i.made.get(bundle)) |png| return if (png.len > 0) png else null;
        if (i.budget == 0) {
            i.pending = true;
            return null;
        }
        i.budget -= 1;
        const png: []u8 = make(i.gpa, bundle) orelse &.{};
        const key = i.gpa.dupe(u8, bundle) catch return null;
        i.made.put(i.gpa, key, png) catch {
            i.gpa.free(key);
            i.gpa.free(png);
            return null;
        };
        return if (png.len > 0) png else null;
    }
};

/// The icon of the app at `bundle`, 64 pixels square (32 points at 2×),
/// as PNG bytes owned by the caller.
fn make(gpa: std.mem.Allocator, bundle: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .windows) return windowsIcon(gpa, bundle);
    if (comptime builtin.os.tag != .macos) return null;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const icon = objc.msg(?objc.Object, ws, "iconForFile:", .{objc.nsString(bundle)}) orelse return null;
    // The representation best for 64 pixels, as a bitmap, as PNG.
    var rect: objc.CGRect = .{ .size = .{ .width = 64, .height = 64 } };
    const cg = objc.msg(?*anyopaque, icon, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg}) orelse return null;
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    const data = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, ptr[0..len]) catch null;
}

// Windows: the icon a program carries, from its resources, through GDI.

const HANDLE = std.os.windows.HANDLE;
const DWORD = u32;

extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, name: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "shell32" fn ExtractIconExW(file: [*:0]const u16, index: i32, large: ?*?HANDLE, small: ?*?HANDLE, n: DWORD) callconv(.winapi) DWORD;
extern "user32" fn DestroyIcon(icon: HANDLE) callconv(.winapi) i32;
extern "user32" fn GetIconInfo(icon: HANDLE, info: *IconInfo) callconv(.winapi) i32;
extern "user32" fn GetDC(window: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn ReleaseDC(window: ?HANDLE, dc: ?HANDLE) callconv(.winapi) i32;
extern "gdi32" fn GetObjectW(obj: HANDLE, size: i32, out: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn GetDIBits(dc: ?HANDLE, bitmap: HANDLE, first: DWORD, lines: DWORD, bits: ?*anyopaque, info: *BitmapInfo, usage: DWORD) callconv(.winapi) i32;
extern "gdi32" fn DeleteObject(obj: HANDLE) callconv(.winapi) i32;

const IconInfo = extern struct {
    fIcon: i32,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: ?HANDLE,
    hbmColor: ?HANDLE,
};

const Bitmap = extern struct {
    bmType: i32,
    bmWidth: i32,
    bmHeight: i32,
    bmWidthBytes: i32,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?*anyopaque,
};

const BitmapInfoHeader = extern struct {
    biSize: DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

const BitmapInfo = extern struct {
    header: BitmapInfoHeader,
    colors: [256]DWORD,
};

comptime {
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(IconInfo) != 32) @compileError("ICONINFO's layout");
        if (@sizeOf(Bitmap) != 32) @compileError("BITMAP's layout");
        if (@sizeOf(BitmapInfoHeader) != 40) @compileError("BITMAPINFOHEADER's layout");
    }
}

const dib_rgb_colors: DWORD = 0;

/// The icon of the program at `path`, as PNG bytes owned by the caller.
fn windowsIcon(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var wide: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
    if (n + 1 > wide.len) return null;
    wide[n] = 0;
    var icon: ?HANDLE = null;
    if (ExtractIconExW(@ptrCast(&wide), 0, &icon, null, 1) == 0) return null;
    const h = icon orelse return null;
    defer _ = DestroyIcon(h);
    var info: IconInfo = undefined;
    if (GetIconInfo(h, &info) == 0) return null;
    defer {
        if (info.hbmMask) |m| _ = DeleteObject(m);
        if (info.hbmColor) |b| _ = DeleteObject(b);
    }
    const color = info.hbmColor orelse return null;
    var bmp: Bitmap = std.mem.zeroes(Bitmap);
    if (GetObjectW(color, @sizeOf(Bitmap), &bmp) == 0) return null;
    const w: usize = @intCast(bmp.bmWidth);
    const hgt: usize = @intCast(bmp.bmHeight);
    if (w == 0 or hgt == 0 or w > 256 or hgt > 256) return null;
    const dc = GetDC(null);
    defer _ = ReleaseDC(null, dc);
    const px = gpa.alloc(u8, w * hgt * 4) catch return null;
    defer gpa.free(px);
    var bi: BitmapInfo = std.mem.zeroes(BitmapInfo);
    bi.header.biSize = @sizeOf(BitmapInfoHeader);
    bi.header.biWidth = @intCast(w);
    bi.header.biHeight = -@as(i32, @intCast(hgt));
    bi.header.biPlanes = 1;
    bi.header.biBitCount = 32;
    if (GetDIBits(dc, color, 0, @intCast(hgt), px.ptr, &bi, dib_rgb_colors) == 0) return null;
    // Older icons carry no alpha: their mask says what is opaque.
    var no_alpha = true;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        if (px[i + 3] != 0) {
            no_alpha = false;
            break;
        }
    }
    if (no_alpha) maskAlpha(gpa, dc, info.hbmMask, px, w, hgt);
    // `ui.png` writes straight RGBA from premultiplied BGRA, as it draws.
    i = 0;
    while (i < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        px[i] = @intCast(@as(u32, px[i]) * a / 255);
        px[i + 1] = @intCast(@as(u32, px[i + 1]) * a / 255);
        px[i + 2] = @intCast(@as(u32, px[i + 2]) * a / 255);
    }
    return nanoui.ui.png.encode(gpa, .{ .bytes = px, .width = w, .height = hgt }) catch null;
}

/// Fills `px`'s alpha from `mask`: a set bit is a hole.
fn maskAlpha(gpa: std.mem.Allocator, dc: ?HANDLE, mask: ?HANDLE, px: []u8, w: usize, h: usize) void {
    const m = mask orelse return;
    const stride = ((w + 31) / 32) * 4;
    const bits = gpa.alloc(u8, stride * h) catch return;
    defer gpa.free(bits);
    @memset(bits, 0);
    var bi: BitmapInfo = std.mem.zeroes(BitmapInfo);
    bi.header.biSize = @sizeOf(BitmapInfoHeader);
    bi.header.biWidth = @intCast(w);
    bi.header.biHeight = -@as(i32, @intCast(h));
    bi.header.biPlanes = 1;
    bi.header.biBitCount = 1;
    if (GetDIBits(dc, m, 0, @intCast(h), bits.ptr, &bi, dib_rgb_colors) == 0) return;
    for (0..h) |y| {
        for (0..w) |x| {
            const bit = (bits[y * stride + x / 8] >> @intCast(7 - x % 8)) & 1;
            px[(y * w + x) * 4 + 3] = if (bit == 1) 0 else 255;
        }
    }
}

test "a Windows program's icon is a PNG" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // A program every Windows install has, and that carries an icon.
    const png = make(gpa, "C:\\Windows\\explorer.exe") orelse return error.NoIcon;
    defer gpa.free(png);
    try std.testing.expect(png.len > 100);
    try std.testing.expectEqualStrings("PNG", png[1..4]);
    // Every chunk adds up: the file ends in IEND.
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 .. png.len - 4]);
}
