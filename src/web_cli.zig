const std = @import("std");
const Io = std.Io;
const web = @import("web.zig");

pub const help_text =
    \\Usage: deez web [--port <port>]
    \\
    \\Start the local Deez Web API on 127.0.0.1.
    \\The default port is 49317.
    \\
;

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "web");
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 3 and isHelp(args[2])) {
        try printHelp(init);
        return;
    }

    const port = try parsePort(args);
    try web.run(init, .{ .port = port });
}

fn parsePort(args: []const []const u8) !u16 {
    if (args.len == 2) return web.default_port;
    if (args.len != 4 or !std.mem.eql(u8, args[2], "--port")) return error.InvalidArguments;

    const port = std.fmt.parseInt(u16, args[3], 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn printHelp(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try out.writeAll(help_text);
}

test "web cli defaults to the fixed local port" {
    const args = [_][]const u8{ "deez", "web" };
    try std.testing.expectEqual(web.default_port, try parsePort(&args));
}

test "web cli accepts an explicit nonzero port" {
    const args = [_][]const u8{ "deez", "web", "--port", "55000" };
    try std.testing.expectEqual(@as(u16, 55000), try parsePort(&args));
}

test "web cli rejects invalid ports and arguments" {
    const zero = [_][]const u8{ "deez", "web", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parsePort(&zero));

    const invalid = [_][]const u8{ "deez", "web", "55000" };
    try std.testing.expectError(error.InvalidArguments, parsePort(&invalid));
}
