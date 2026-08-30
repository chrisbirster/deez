const std = @import("std");

const config = @import("config.zig");
const hosted_runtime = @import("hosted_runtime.zig");
const storage = @import("storage/root.zig");
const web = @import("web.zig");
const web_assets = @import("web_assets.zig");

pub const Options = struct {
    port: u16 = 5882,
    bind: web.Bind = .loopback,
    web_root: ?[]const u8 = null,
};

pub const help_text =
    \\Deez HTTP server:
    \\  deez serve [--port <1..65535>] [--host 127.0.0.1|0.0.0.0] [--web-root <path>]
    \\
    \\Serves the canonical Deez JSON API and, when available, a built SPA.
    \\The default endpoint remains local-only at 127.0.0.1:5882.
    \\Use --host 0.0.0.0 for container/hosted deployments such as Fly.io.
    \\
    \\Web assets are resolved in this order:
    \\  1. --web-root <path>
    \\  2. DEEZ_WEB_ROOT
    \\  3. packaged web assets beside the installed deez binary
;

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "serve");
}

fn parsePort(text: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseHost(text: []const u8) !web.Bind {
    if (std.mem.eql(u8, text, "127.0.0.1") or std.ascii.eqlIgnoreCase(text, "localhost")) return .loopback;
    if (std.mem.eql(u8, text, "0.0.0.0")) return .all;
    return error.InvalidHost;
}

fn parseOptions(args: []const []const u8) !Options {
    if (!isCommand(args)) return error.InvalidArguments;

    var options: Options = .{};
    var index: usize = 2;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            options.port = try parsePort(args[index + 1]);
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            options.bind = try parseHost(args[index + 1]);
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

pub fn runCommand(init: std.process.Init, args: []const []const u8) !void {
    try run(init, try parseOptions(args));
}

pub fn run(init: std.process.Init, options: Options) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const web_root = try web_assets.resolveRoot(init, options.web_root);
    const selection = try config.resolve(init);

    switch (selection.backend) {
        .mongodb => {
            const mongo = try storage.MongoStore.connect(init.io, allocator, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            if (options.bind == .all) {
                try hosted_runtime.run(init, &store, .{ .port = options.port, .web_root = web_root });
                return;
            }
            try web.run(init, &store, .{
                .port = options.port,
                .web_root = web_root,
                .open_browser = false,
                .bind = options.bind,
            });
        },
        .sqlite => {
            if (options.bind == .all) return error.HostedRequiresMongoDB;
            const db_path_z = try arena.dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            try web.run(init, &store, .{
                .port = options.port,
                .web_root = web_root,
                .open_browser = false,
                .bind = options.bind,
            });
        },
    }
}

test "serve defaults remain local and support hosted web serving" {
    const default_args = [_][]const u8{ "deez", "serve" };
    const defaults = try parseOptions(&default_args);
    try std.testing.expectEqual(@as(u16, 5882), defaults.port);
    try std.testing.expectEqual(web.Bind.loopback, defaults.bind);
    try std.testing.expect(defaults.web_root == null);

    const hosted_args = [_][]const u8{
        "deez",
        "serve",
        "--host",
        "0.0.0.0",
        "--port",
        "8080",
        "--web-root",
        "/app/web",
    };
    const hosted = try parseOptions(&hosted_args);
    try std.testing.expectEqual(@as(u16, 8080), hosted.port);
    try std.testing.expectEqual(web.Bind.all, hosted.bind);
    try std.testing.expectEqualStrings("/app/web", hosted.web_root.?);
}

test "serve rejects invalid host port and incomplete options" {
    const invalid_host = [_][]const u8{ "deez", "serve", "--host", "example.com" };
    try std.testing.expectError(error.InvalidHost, parseOptions(&invalid_host));

    const zero = [_][]const u8{ "deez", "serve", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero));

    const missing_root = [_][]const u8{ "deez", "serve", "--web-root" };
    try std.testing.expectError(error.InvalidArguments, parseOptions(&missing_root));
}
