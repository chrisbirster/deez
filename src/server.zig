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
    io: Io,
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
    var app: App = .{ .allocator = allocator, .io = io, .store = store };
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
    router.get("/api/v1/decks", listDecks, .{});
    router.get("/api/v1/decks/:deck_id", getDeck, .{});
    router.get("/api/v1/decks/:deck_id/notes", listNotes, .{});
    router.get("/api/v1/notes/:note_id", getNote, .{});
    router.get("/api/v1/decks/:deck_id/cards", listCards, .{});
    router.get("/api/v1/cards/:card_id", getCard, .{});

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("Deez API: http://127.0.0.1:{d}\n", .{options.port});
    try out.flush();

    try server.listen();
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn writeError(
    res: *httpz.Response,
    status: u16,
    code: []const u8,
    message: []const u8,
) !void {
    res.status = status;
    try res.json(.{
        .error = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn pathId(req: *httpz.Request, name: []const u8) !u64 {
    const raw = req.param(name) orelse return error.InvalidId;
    return std.fmt.parseInt(u64, raw, 10) catch return error.InvalidId;
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

fn listDecks(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    const decks = try app.store.decks(app.allocator, nowMs(app.io));
    defer {
        for (decks) |deck| deck.deinit(app.allocator);
        app.allocator.free(decks);
    }
    try res.json(.{ .decks = decks }, .{});
}

fn getDeck(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    try res.json(.{
        .deck = .{
            .id = deck.id,
            .name = deck.name,
        },
    }, .{});
}

fn listCards(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    const cards = try app.store.cards(app.allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(app.allocator);
        app.allocator.free(cards);
    }
    try res.json(.{ .cards = cards }, .{});
}

fn getCard(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const card_id = pathId(req, "card_id") catch
        return writeError(res, 400, "invalid_id", "card_id must be an unsigned integer");
    const card = (try app.store.getCard(app.allocator, card_id)) orelse
        return writeError(res, 404, "card_not_found", "card does not exist");
    defer card.deinit(app.allocator);
    try res.json(.{ .card = card }, .{});
}

fn hasNote(notes: []const content.OwnedNote, note_id: content.NoteId) bool {
    for (notes) |note| {
        if (note.id == note_id) return true;
    }
    return false;
}

fn listNotes(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    const cards = try app.store.cards(app.allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(app.allocator);
        app.allocator.free(cards);
    }

    const content_store = storage.ContentStore.init(app.store);
    var notes: std.ArrayList(content.OwnedNote) = .empty;
    defer {
        for (notes.items) |note| note.deinit(app.allocator);
        notes.deinit(app.allocator);
    }

    for (cards) |card| {
        const source = (try content_store.cardSource(app.allocator, card.id)) orelse continue;
        defer source.deinit(app.allocator);
        if (hasNote(notes.items, source.note_id)) continue;
        const note = (try content_store.getNote(app.allocator, source.note_id)) orelse continue;
        errdefer note.deinit(app.allocator);
        try notes.append(app.allocator, note);
    }

    try res.json(.{ .notes = notes.items }, .{});
}

fn getNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const note_id = pathId(req, "note_id") catch
        return writeError(res, 400, "invalid_id", "note_id must be an unsigned integer");
    const content_store = storage.ContentStore.init(app.store);
    const note = (try content_store.getNote(app.allocator, note_id)) orelse
        return writeError(res, 404, "note_not_found", "note does not exist");
    defer note.deinit(app.allocator);
    try res.json(.{ .note = note }, .{});
}

test "serve options are loopback-port only" {
    const default_args = [_][]const u8{ "deez", "serve" };
    try std.testing.expectEqual(@as(u16, 5882), (try parseOptions(&default_args)).port);

    const custom_args = [_][]const u8{ "deez", "serve", "--port", "9000" };
    try std.testing.expectEqual(@as(u16, 9000), (try parseOptions(&custom_args)).port);

    const zero_args = [_][]const u8{ "deez", "serve", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero_args));
}
