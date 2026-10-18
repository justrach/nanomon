//! Apps' icons in the table, as Activity Monitor shows them: the system's
//! icon for an app's bundle, drawn small and kept as PNG bytes for
//! `ui.image` (macOS; elsewhere processes go without). Made on the main
//! thread, once a bundle, a few a frame so a first screenful does not stall.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

pub const supported = builtin.os.tag == .macos;

/// New icons made in one frame at most; the rest come in the next ones.
pub const per_frame = 6;

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
    if (comptime !supported) return null;
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
