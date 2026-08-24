const std = @import("std");
const builtin = @import("builtin");

pub fn openDefault(allocator: std.mem.Allocator, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        .windows => &.{ "cmd.exe", "/C", "start", "", url },
        else => return error.UnsupportedBrowserOpenPlatform,
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.BrowserOpenFailed,
        else => return error.BrowserOpenFailed,
    }
}
