//! First-launch consent and per-client results. Rendering this view alone
//! does no IO; only the explicit buttons invoke the setup controller.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const clients = @import("mcp_clients.zig");
const reg = @import("mcp_register.zig");

pub fn banner(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.agents;
    switch (s.state) {
        .off, .closed => return,
        else => {},
    }
    const box = ui.div(c).column().wFull().p(14).gap(5).bg(k.card);
    defer box.end();
    ui.text(c, "Connect agents to nanomon", .{ .size = 13, .weight = .semibold, .color = k.text });
    switch (s.state) {
        .offer => {
            ui.text(c, "Read-only CPU, memory and process details may be sent to these agents and their model providers. No process control.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
            {
                const row = ui.div(c).row().wFull().gap(10);
                defer row.end();
                for (clients.all, s.detected) |client, found| if (found) ui.text(c, clients.name(client), .{ .size = 11, .color = k.text });
            }
            if (s.count() == 0) ui.text(c, "No supported client profiles detected. Open a client once, then try again.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            if (s.count() > 0 and ui.button(c, "Connect detected clients", .{ .size = 12 }).clicked) {
                s.connect();
                c.changed = true;
            }
            if (ui.button(c, "Not now", .{ .variant = .ghost, .size = 12 }).clicked) {
                s.dismiss();
                c.changed = true;
            }
        },
        .running => ui.text(c, "Connecting… existing settings and custom entries are preserved.", .{ .size = 11.5, .color = k.secondary }),
        .done => {
            if (s.failed) {
                ui.text(c, "Setup could not finish. Try nanomon mcp install --dry-run from a terminal.", .{ .size = 11.5, .color = k.red, .wrap = true });
            } else {
                for (s.report) |row| if (row.state != .absent) ui.text(c, c.print("{s}: {s}", .{ clients.name(row.client), reg.message(row.state) }), .{ .size = 11, .color = k.secondary, .wrap = true });
                ui.text(c, "Restart connected clients to discover the tools. Backups are beside changed configs. Undo: nanomon mcp uninstall", .{ .size = 11, .color = k.secondary, .wrap = true });
            }
            if (s.choice_failed) ui.text(c, "Could not save your setup preference.", .{ .size = 11, .color = k.red });
            if (ui.button(c, "Done", .{ .size = 12 }).clicked) {
                s.dismiss();
                c.changed = true;
            }
        },
        else => {},
    }
}

pub fn button(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.agents.opened == null) return;
    if (ui.button(c, "Agent connections…", .{ .variant = .ghost, .size = 11 }).clicked) {
        a.agents.show();
        c.changed = true;
    }
    _ = k;
}
