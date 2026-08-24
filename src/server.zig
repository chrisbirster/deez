const std = @import("std");
const httpz = @import("httpz");

const config = @import("config.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");

const Io = std.Io;

pub const Options = struct {
    port: u16 = 5882,
};

pub const help_text =
    \\Local API server:
    \\  deez serve [--port <1..65535>]
    \\
    \\Binds to 127.0.0.1 only. The default port is 5882.
;

const version = std.mem.trim(u8, @embedFile("../VERSION"), " \t\r\n");

const App = struct {
    allocator: std.mem.Allocator,
    store: *storage.Store,
};

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "serve");
}

fn parsePort(text: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 2) return .{};
    if (args.len == 4 and std.mem.eql(u8, args[2], "--port")) {
        return .{ .port = try parsePort(args[3]) };
    }
    return error.InvalidArguments;
}

pub fn runCommand(init: std.process.Init, args: []const []const u8) !void {
    try run(init, try parseOptions(args));
}

pub fn run(init: std.process.Init, options: Options) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);

    switch (selection.backend) {
        .mongodb => {
            const mongo = try storage.MongoStore.connect(io, allocator, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            try serveWithStore(allocator, io, &store, options);
        },
        .sqlite => {
            const db_path_z = try arena.dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            try serveWithStore(allocator, io, &store, options);
        },
    }
}

fn serveWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    options: Options,
) !void {
    var app: App = .{ .allocator = allocator, .store = store };
    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = .localhost(options.port),
        .workers = .{
            .count = 1,
            .max_conn = 64,
        },
        .thread_pool = .{
            .count = 1,
            .backlog = 64,
        },
        .request = .{
            .max_body_size = 1024 * 1024,
            .max_header_count = 32,
            .max_param_count = 16,
            .max_query_count = 32,
        },
        .response = .{ .max_header_count = 32 },
        .timeout = .{
            .request = 15,
            .keepalive = 10,
            .request_count = 100,
        },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/version", versionInfo, .{});
    router.get("/api/v1/capabilities", capabilities, .{});

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("Deez API: http://127.0.0.1:{d}\n", .{options.port});
    try out.flush();

    try server.listen();
}

fn health(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try res.json(.{ .status = "ok" }, .{});
}

fn versionInfo(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try res.json(.{ .version = version }, .{});
}

fn capabilities(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;

    var note_types: [content.built_in_note_types.len][]const u8 = undefined;
    for (content.built_in_note_types, 0..) |definition, index| {
        note_types[index] = definition.slug;
    }

    const interactions = [_][]const u8{
        "reveal",
        "type_answer",
        "single_choice",
        "multiple_choice",
        "ordering",
        "image_occlusion",
    };

    try res.json(.{
        .note_types = note_types[0..],
        .interactions = interactions[0..],
    }, .{});
}

test "serve options are loopback-port only" {
    const default_args = [_][]const u8{ "deez", "serve" };
    try std.testing.expectEqual(@as(u16, 5882), (try parseOptions(&default_args)).port);

    const custom_args = [_][]const u8{ "deez", "serve", "--port", "9000" };
    try std.testing.expectEqual(@as(u16, 9000), (try parseOptions(&custom_args)).port);

    const zero_args = [_][]const u8{ "deez", "serve", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero_args));
}
