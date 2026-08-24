const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const storage = @import("storage/root.zig");
const web = @import("web.zig");
const web_assets = @import("web_assets.zig");

pub const help_text =
    \\Usage: deez web [--port <port>] [--web-root <path>]
    \\
    \\Start the local Deez Web app on 127.0.0.1.
    \\The default port is 49317.
    \\
    \\Web assets are resolved in this order:
    \\  1. --web-root <path>
    \\  2. DEEZ_WEB_ROOT
    \\  3. packaged web assets beside the installed deez binary
    \\
;

const CliOptions = struct {
    port: u16 = web.default_port,
    web_root: ?[]const u8 = null,
};

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "web");
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 3 and isHelp(args[2])) {
        try printHelp(init);
        return;
    }

    const options = try parseOptions(args);
    const web_root = try web_assets.resolveRoot(init, options.web_root);
    const selection = try config.resolve(init);

    switch (selection.backend) {
        .mongodb => {
            const mongo = try storage.MongoStore.connect(init.io, init.gpa, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            try web.run(init, &store, .{ .port = options.port, .web_root = web_root });
        },
        .sqlite => {
            const db_path_z = try init.arena.allocator().dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            try web.run(init, &store, .{ .port = options.port, .web_root = web_root });
        },
    }
}

fn parseOptions(args: []const []const u8) !CliOptions {
    if (args.len < 2) return error.InvalidArguments;

    var options: CliOptions = .{};
    var index: usize = 2;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            const port = std.fmt.parseInt(u16, args[index + 1], 10) catch return error.InvalidPort;
            if (port == 0) return error.InvalidPort;
            options.port = port;
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--web-root")) {
            if (index + 1 >= args.len or args[index + 1].len == 0) return error.InvalidArguments;
            options.web_root = args[index + 1];
            index += 2;
            continue;
        }
        return error.InvalidArguments;
    }
    return options;
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn printHelp(init: std.process.Init) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try out.writeAll(help_text);
}

test "web cli defaults to the fixed local port" {
    const args = [_][]const u8{ "deez", "web" };
    const options = try parseOptions(&args);
    try std.testing.expectEqual(web.default_port, options.port);
    try std.testing.expect(options.web_root == null);
}

test "web cli accepts port and web root in either order" {
    const first = [_][]const u8{ "deez", "web", "--port", "55000", "--web-root", "/tmp/deez-web" };
    const first_options = try parseOptions(&first);
    try std.testing.expectEqual(@as(u16, 55000), first_options.port);
    try std.testing.expectEqualStrings("/tmp/deez-web", first_options.web_root.?);

    const second = [_][]const u8{ "deez", "web", "--web-root", "/tmp/deez-web", "--port", "55001" };
    const second_options = try parseOptions(&second);
    try std.testing.expectEqual(@as(u16, 55001), second_options.port);
    try std.testing.expectEqualStrings("/tmp/deez-web", second_options.web_root.?);
}

test "web cli rejects invalid ports and arguments" {
    const zero = [_][]const u8{ "deez", "web", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero));

    const missing_root = [_][]const u8{ "deez", "web", "--web-root" };
    try std.testing.expectError(error.InvalidArguments, parseOptions(&missing_root));

    const invalid = [_][]const u8{ "deez", "web", "55000" };
    try std.testing.expectError(error.InvalidArguments, parseOptions(&invalid));
}
