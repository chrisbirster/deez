const std = @import("std");

const config = @import("config.zig");
const content = @import("content.zig");
const fsrs = @import("fsrs/root.zig");
const note_mutation = @import("note_mutation.zig");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const max_http_body_bytes: usize = 16 * 1024 * 1024;
const default_base_url = "https://deez.run";
const cookie_name = "__Host-deez_session";

pub const help_text =
    "Cloud account and sync:\n" ++
    "  deez login <email>          Sign in to deez.run with a magic link\n" ++
    "  deez whoami                 Show the signed-in cloud account\n" ++
    "  deez sync                   Bidirectionally sync local Deez with deez.run\n" ++
    "  deez logout                 Revoke this CLI cloud session\n\n" ++
    "Environment:\n" ++
    "  DEEZ_CLOUD_URL              Override https://deez.run (development/testing)\n\n";

const CloudConfig = struct {
    version: u32 = 1,
    base_url: []const u8,
    session: []const u8,
};

const CloudUser = struct {
    id: []const u8,
    email: []const u8,
    username: ?[]const u8 = null,
};

const ConsumeResponse = struct {
    user: CloudUser,
    needs_username: bool,
    is_new_user: bool,
};

const RemoteDeck = struct {
    id: []const u8,
    name: []const u8,
    note_count: usize = 0,
    card_count: usize = 0,
    due_count: usize = 0,
};

const RemoteNoteSummary = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    preview: []const u8 = "",
    card_count: usize = 0,
    updated_at_ms: i64 = 0,
};

const RemoteNote = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    fields: []const []const u8,
    tags: []const []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const RemoteGeneration = struct {
    kind: []const u8,
    ordinal: u32,
};

const RemoteCardSummary = struct {
    id: []const u8,
    deck_id: []const u8,
    front: []const u8 = "",
    note_id: ?[]const u8 = null,
    generation: ?RemoteGeneration = null,
    due_at_ms: ?i64 = null,
    last_reviewed_at_ms: ?i64 = null,
};

const RemoteReview = struct {
    rating: u8,
    reviewed_at_ms: i64,
};

const RemoteCard = struct {
    id: []const u8,
    deck_id: []const u8,
    note_id: ?[]const u8 = null,
    note_type: ?[]const u8 = null,
    generation: ?RemoteGeneration = null,
    review_count: usize,
    reviews: []const RemoteReview = &.{},
};

const DeckMap = struct {
    local_id: u64,
    remote_id: u64,
    last_hash: u64,
};

const NoteMap = struct {
    local_id: u64,
    remote_id: u64,
    local_deck_id: u64,
    remote_deck_id: u64,
    last_hash: u64,
};

const PersistedSync = struct {
    version: u32 = 1,
    decks: []const DeckMap = &.{},
    notes: []const NoteMap = &.{},
};

const SyncState = struct {
    decks: std.ArrayList(DeckMap) = .empty,
    notes: std.ArrayList(NoteMap) = .empty,
};

const RawResponse = struct {
    status: u16,
    body: []u8,
    session: ?[]u8 = null,
};

const SyncCounters = struct {
    pushed_decks: usize = 0,
    pulled_decks: usize = 0,
    pushed_notes: usize = 0,
    pulled_notes: usize = 0,
    pushed_reviews: usize = 0,
    pulled_reviews: usize = 0,
    conflicts: usize = 0,
};

pub fn isCommand(args: []const []const u8) bool {
    if (args.len < 2) return false;
    return std.mem.eql(u8, args[1], "login") or
        std.mem.eql(u8, args[1], "whoami") or
        std.mem.eql(u8, args[1], "sync") or
        std.mem.eql(u8, args[1], "logout");
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn home(init: std.process.Init) ![]const u8 {
    return init.environ_map.get("HOME") orelse error.MissingHomeDirectory;
}

fn configDir(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez", .{home_dir});
}

fn cloudConfigPath(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez/cloud.json", .{home_dir});
}

fn syncStatePath(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez/sync.json", .{home_dir});
}

fn writePrivateFile(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    file.setPermissions(init.io, @enumFromInt(0o600)) catch {};
    try file.writeStreamingAll(init.io, bytes);
}

fn stringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn saveCloudConfig(init: std.process.Init, value: CloudConfig) !void {
    const allocator = init.arena.allocator();
    const dir = try configDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try cloudConfigPath(allocator, try home(init));
    const bytes = try stringifyAlloc(allocator, value);
    try writePrivateFile(init, path, bytes);
}

fn loadCloudConfig(init: std.process.Init) !CloudConfig {
    const allocator = init.arena.allocator();
    const path = try cloudConfigPath(allocator, try home(init));
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.NotLoggedIn,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(CloudConfig, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn deleteCloudConfig(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const path = cloudConfigPath(allocator, home(init) catch return) catch return;
    Io.Dir.deleteFileAbsolute(init.io, path) catch {};
}

fn loadSyncState(init: std.process.Init) !SyncState {
    const allocator = init.arena.allocator();
    var state: SyncState = .{};
    const path = try syncStatePath(allocator, try home(init));
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return state,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(PersistedSync, allocator, bytes, .{ .ignore_unknown_fields = true });
    try state.decks.appendSlice(allocator, parsed.value.decks);
    try state.notes.appendSlice(allocator, parsed.value.notes);
    return state;
}

fn saveSyncState(init: std.process.Init, state: *const SyncState) !void {
    const allocator = init.arena.allocator();
    const dir = try configDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try syncStatePath(allocator, try home(init));
    const bytes = try stringifyAlloc(allocator, PersistedSync{
        .decks = state.decks.items,
        .notes = state.notes.items,
    });
    try writePrivateFile(init, path, bytes);
}

fn readByte(io: Io) !u8 {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{buffer[0..]};
    const read = try Io.File.stdin().readStreaming(io, &buffers);
    if (read == 0) return error.EndOfStream;
    return buffer[0];
}

fn readLine(allocator: Allocator, io: Io) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = readByte(io) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte != '\r') try bytes.append(allocator, byte);
    }
    return bytes.toOwnedSlice(allocator);
}

fn extractSession(allocator: Allocator, head: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const prefix = cookie_name ++ "=";
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const rest = value[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        return try allocator.dupe(u8, rest[0..end]);
    }
    return null;
}

fn httpRequest(
    init: std.process.Init,
    method: std.http.Method,
    url: []const u8,
    session: ?[]const u8,
    body: ?[]const u8,
) !RawResponse {
    const allocator = init.arena.allocator();
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var headers: [4]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "Accept", .value = "application/json" };
    count += 1;
    headers[count] = .{ .name = "User-Agent", .value = "deez-cli/1" };
    count += 1;
    var cookie_header: ?[]u8 = null;
    if (session) |token| {
        cookie_header = try std.fmt.allocPrint(allocator, "{s}={s}", .{ cookie_name, token });
        headers[count] = .{ .name = "Cookie", .value = cookie_header.? };
        count += 1;
    }
    if (body != null) {
        headers[count] = .{ .name = "Content-Type", .value = "application/json" };
        count += 1;
    }

    const uri = try std.Uri.parse(url);
    var request = try client.request(method, uri, .{ .extra_headers = headers[0..count] });
    defer request.deinit();
    if (body) |bytes| {
        try request.sendBodyComplete(@constCast(bytes));
    } else {
        try request.sendBodiless();
    }

    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    const new_session = try extractSession(allocator, response.head.bytes);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const response_body = try reader.allocRemaining(allocator, .limited(max_http_body_bytes));
    return .{ .status = status, .body = response_body, .session = new_session };
}

fn apiUrl(allocator: Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1{s}", .{ std.mem.trimEnd(u8, base_url, "/"), path });
}

fn requireSuccess(response: RawResponse) !void {
    if (response.status >= 200 and response.status < 300) return;
    std.log.err("deez.run returned HTTP {d}: {s}", .{ response.status, response.body });
    return error.CloudRequestFailed;
}

fn requestJson(
    comptime T: type,
    init: std.process.Init,
    cloud: CloudConfig,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) !T {
    const allocator = init.arena.allocator();
    const url = try apiUrl(allocator, cloud.base_url, path);
    const response = try httpRequest(init, method, url, cloud.session, body);
    try requireSuccess(response);
    const parsed = try std.json.parseFromSlice(T, allocator, response.body, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn requestVoid(
    init: std.process.Init,
    cloud: CloudConfig,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) !void {
    const url = try apiUrl(init.arena.allocator(), cloud.base_url, path);
    const response = try httpRequest(init, method, url, cloud.session, body);
    try requireSuccess(response);
}

fn baseUrl(init: std.process.Init) []const u8 {
    return init.environ_map.get("DEEZ_CLOUD_URL") orelse default_base_url;
}

fn parseMagicToken(input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 64) return trimmed;
    const marker = "token=";
    const start = (std.mem.indexOf(u8, trimmed, marker) orelse return error.InvalidMagicLink) + marker.len;
    var end = trimmed.len;
    if (std.mem.indexOfScalarPos(u8, trimmed, start, '&')) |index| end = @min(end, index);
    if (std.mem.indexOfScalarPos(u8, trimmed, start, '#')) |index| end = @min(end, index);
    const token = trimmed[start..end];
    if (token.len != 64) return error.InvalidMagicLink;
    return token;
}

fn login(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const allocator = init.arena.allocator();
    const base = baseUrl(init);
    const request_url = try apiUrl(allocator, base, "/auth/magic-link");
    const request_body = try stringifyAlloc(allocator, .{ .email = args[2] });
    const requested = try httpRequest(init, .POST, request_url, null, request_body);
    try requireSuccess(requested);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("Magic link sent to {s}.\nPaste the link from the email here (it is read only by this process): ", .{args[2]});
    try out.flush();

    const line = try readLine(allocator, init.io);
    const token = try parseMagicToken(line);
    const consume_url = try apiUrl(allocator, base, "/auth/magic/consume");
    const consume_body = try stringifyAlloc(allocator, .{ .token = token });
    const consumed = try httpRequest(init, .POST, consume_url, null, consume_body);
    try requireSuccess(consumed);
    const session = consumed.session orelse return error.MissingCloudSession;
    const parsed = try std.json.parseFromSlice(ConsumeResponse, allocator, consumed.body, .{ .ignore_unknown_fields = true });
    try saveCloudConfig(init, .{ .base_url = base, .session = session });

    try out.print("Signed in as {s}", .{parsed.value.user.email});
    if (parsed.value.user.username) |username| try out.print(" (@{s})", .{username});
    try out.writeAll(".\n");
    if (parsed.value.needs_username) try out.writeAll("Open deez.run once to choose a username.\n");
    try out.flush();
}

fn whoami(init: std.process.Init) !void {
    const cloud = try loadCloudConfig(init);
    const user = try requestJson(CloudUser, init, cloud, .GET, "/auth/me", null);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try out.print("{s}", .{user.email});
    if (user.username) |username| try out.print(" (@{s})", .{username});
    try out.print("\n{s}\n", .{cloud.base_url});
}

fn logout(init: std.process.Init) !void {
    const cloud = loadCloudConfig(init) catch |err| switch (err) {
        error.NotLoggedIn => {
            deleteCloudConfig(init);
            return;
        },
        else => return err,
    };
    requestVoid(init, cloud, .POST, "/auth/logout", null) catch {};
    deleteCloudConfig(init);
}

fn parseRemoteId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidCloudId;
}

fn hashDeckName(name: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(name);
    return hash.final();
}

fn hashNoteParts(note_type: []const u8, fields: []const []const u8, tags: []const []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(note_type);
    hash.update(&[_]u8{0});
    for (fields) |field| {
        hash.update(field);
        hash.update(&[_]u8{0});
    }
    hash.update(&[_]u8{0xff});
    for (tags) |tag| {
        hash.update(tag);
        hash.update(&[_]u8{0});
    }
    return hash.final();
}

fn localTags(allocator: Allocator, tags_json: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice([]const []const u8, allocator, tags_json, .{});
    return parsed.value;
}

fn localNoteHash(allocator: Allocator, note: content.OwnedNote) !u64 {
    const kind = try content.BuiltInNoteType.fromId(note.note_type_id);
    const fields = try allocator.alloc([]const u8, note.fields.len);
    for (note.fields, 0..) |field, index| fields[index] = field.value;
    return hashNoteParts(kind.definition().slug, fields, try localTags(allocator, note.tags_json));
}

fn remoteNoteHash(note: RemoteNote) u64 {
    return hashNoteParts(note.note_type, note.fields, note.tags);
}

fn findDeckLocal(state: *SyncState, local_id: u64) ?*DeckMap {
    for (state.decks.items) |*entry| if (entry.local_id == local_id) return entry;
    return null;
}

fn findDeckRemote(state: *SyncState, remote_id: u64) ?*DeckMap {
    for (state.decks.items) |*entry| if (entry.remote_id == remote_id) return entry;
    return null;
}

fn findNoteLocal(state: *SyncState, local_id: u64) ?*NoteMap {
    for (state.notes.items) |*entry| if (entry.local_id == local_id) return entry;
    return null;
}

fn findNoteRemote(state: *SyncState, remote_id: u64) ?*NoteMap {
    for (state.notes.items) |*entry| if (entry.remote_id == remote_id) return entry;
    return null;
}

fn listRemoteDecks(init: std.process.Init, cloud: CloudConfig) ![]const RemoteDeck {
    return requestJson([]const RemoteDeck, init, cloud, .GET, "/decks", null);
}

fn listRemoteNotes(init: std.process.Init, cloud: CloudConfig, remote_deck_id: u64) ![]const RemoteNoteSummary {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/decks/{d}/notes", .{remote_deck_id});
    return requestJson([]const RemoteNoteSummary, init, cloud, .GET, path, null);
}

fn getRemoteNote(init: std.process.Init, cloud: CloudConfig, remote_note_id: u64) !RemoteNote {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/notes/{d}", .{remote_note_id});
    return requestJson(RemoteNote, init, cloud, .GET, path, null);
}

fn listRemoteCards(init: std.process.Init, cloud: CloudConfig, remote_deck_id: u64) ![]const RemoteCardSummary {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/decks/{d}/cards", .{remote_deck_id});
    return requestJson([]const RemoteCardSummary, init, cloud, .GET, path, null);
}

fn getRemoteCard(init: std.process.Init, cloud: CloudConfig, remote_card_id: u64) !RemoteCard {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/cards/{d}", .{remote_card_id});
    return requestJson(RemoteCard, init, cloud, .GET, path, null);
}

fn createRemoteDeck(init: std.process.Init, cloud: CloudConfig, name: []const u8) !RemoteDeck {
    const body = try stringifyAlloc(init.arena.allocator(), .{ .name = name });
    return requestJson(RemoteDeck, init, cloud, .POST, "/decks", body);
}

fn renameRemoteDeck(init: std.process.Init, cloud: CloudConfig, remote_id: u64, name: []const u8) !RemoteDeck {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "/decks/{d}", .{remote_id});
    const body = try stringifyAlloc(init.arena.allocator(), .{ .name = name });
    return requestJson(RemoteDeck, init, cloud, .PATCH, path, body);
}

fn createRemoteNote(init: std.process.Init, cloud: CloudConfig, remote_deck_id: u64, note: content.OwnedNote) !RemoteNote {
    const allocator = init.arena.allocator();
    const kind = try content.BuiltInNoteType.fromId(note.note_type_id);
    const fields = try allocator.alloc([]const u8, note.fields.len);
    for (note.fields, 0..) |field, index| fields[index] = field.value;
    const body = try stringifyAlloc(allocator, .{
        .note_type = kind.definition().slug,
        .fields = fields,
        .tags = try localTags(allocator, note.tags_json),
    });
    const path = try std.fmt.allocPrint(allocator, "/decks/{d}/notes", .{remote_deck_id});
    return requestJson(RemoteNote, init, cloud, .POST, path, body);
}

fn updateRemoteNote(init: std.process.Init, cloud: CloudConfig, remote_id: u64, note: content.OwnedNote) !RemoteNote {
    const allocator = init.arena.allocator();
    const kind = try content.BuiltInNoteType.fromId(note.note_type_id);
    const fields = try allocator.alloc([]const u8, note.fields.len);
    for (note.fields, 0..) |field, index| fields[index] = field.value;
    const body = try stringifyAlloc(allocator, .{
        .note_type = kind.definition().slug,
        .fields = fields,
        .tags = try localTags(allocator, note.tags_json),
    });
    const path = try std.fmt.allocPrint(allocator, "/notes/{d}", .{remote_id});
    return requestJson(RemoteNote, init, cloud, .PATCH, path, body);
}

fn remoteTagsJson(allocator: Allocator, tags: []const []const u8) ![]u8 {
    return stringifyAlloc(allocator, tags);
}

fn valuesFromRemote(allocator: Allocator, fields: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, fields.len);
    @memcpy(result, fields);
    return result;
}

fn createLocalNote(
    allocator: Allocator,
    store: *storage.Store,
    local_deck_id: u64,
    note: RemoteNote,
) !u64 {
    const kind = try content.BuiltInNoteType.parseStored(note.note_type);
    const created = try note_mutation.create(
        allocator,
        store,
        local_deck_id,
        kind,
        try valuesFromRemote(allocator, note.fields),
        try remoteTagsJson(allocator, note.tags),
        note.created_at_ms,
    );
    return created.note_id;
}

fn updateLocalNote(
    allocator: Allocator,
    store: *storage.Store,
    local_deck_id: u64,
    local_note_id: u64,
    note: RemoteNote,
) !void {
    const existing = (try storage.ContentStore.init(store).getNote(allocator, local_note_id)) orelse return error.NoteNotFound;
    const existing_kind = try content.BuiltInNoteType.fromId(existing.note_type_id);
    const remote_kind = try content.BuiltInNoteType.parseStored(note.note_type);
    if (existing_kind != remote_kind) return error.SyncNoteTypeConflict;
    _ = try note_mutation.update(
        allocator,
        store,
        local_deck_id,
        local_note_id,
        try valuesFromRemote(allocator, note.fields),
        try remoteTagsJson(allocator, note.tags),
        note.updated_at_ms,
    );
}

fn generationFromKey(key: []const u8) !RemoteGeneration {
    var parts = std.mem.splitScalar(u8, key, ':');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidGenerationKey, "note")) return error.InvalidGenerationKey;
    _ = parts.next() orelse return error.InvalidGenerationKey;
    const kind = parts.next() orelse return error.InvalidGenerationKey;
    const ordinal_text = parts.next() orelse return error.InvalidGenerationKey;
    if (parts.next() != null) return error.InvalidGenerationKey;
    return .{
        .kind = kind,
        .ordinal = std.fmt.parseInt(u32, ordinal_text, 10) catch return error.InvalidGenerationKey,
    };
}

fn generationEqual(left: RemoteGeneration, right: RemoteGeneration) bool {
    return left.ordinal == right.ordinal and std.mem.eql(u8, left.kind, right.kind);
}

fn reviewEqual(local: fsrs.HistoryEntry, remote: RemoteReview) bool {
    return local.rating.value() == remote.rating and local.reviewed_at_ms == remote.reviewed_at_ms;
}

fn postRemoteReview(
    init: std.process.Init,
    cloud: CloudConfig,
    remote_card_id: u64,
    expected_count: usize,
    review: fsrs.HistoryEntry,
) !void {
    const allocator = init.arena.allocator();
    const path = try std.fmt.allocPrint(allocator, "/cards/{d}/reviews", .{remote_card_id});
    const body = try stringifyAlloc(allocator, .{
        .rating = review.rating.value(),
        .expected_review_count = expected_count,
        .reviewed_at_ms = review.reviewed_at_ms,
    });
    try requestVoid(init, cloud, .POST, path, body);
}

fn syncCardReviews(
    init: std.process.Init,
    store: *storage.Store,
    cloud: CloudConfig,
    local_card_id: u64,
    remote_card_id: u64,
    counters: *SyncCounters,
) !void {
    const allocator = init.arena.allocator();
    const local_history = try store.loadHistory(allocator, local_card_id);
    const remote_card = try getRemoteCard(init, cloud, remote_card_id);
    const remote_history = remote_card.reviews;
    const common = @min(local_history.len, remote_history.len);
    for (0..common) |index| {
        if (!reviewEqual(local_history[index], remote_history[index])) {
            counters.conflicts += 1;
            return;
        }
    }

    if (local_history.len > remote_history.len) {
        var expected = remote_history.len;
        for (local_history[remote_history.len..]) |review| {
            try postRemoteReview(init, cloud, remote_card_id, expected, review);
            expected += 1;
            counters.pushed_reviews += 1;
        }
        return;
    }

    if (remote_history.len > local_history.len) {
        const study = study_mod.Study.init(store);
        for (remote_history[local_history.len..]) |review| {
            const rating = try fsrs.Rating.fromValue(review.rating);
            _ = try study.recordReview(allocator, local_card_id, rating, review.reviewed_at_ms);
            counters.pulled_reviews += 1;
        }
    }
}

fn syncReviewsForNote(
    init: std.process.Init,
    store: *storage.Store,
    cloud: CloudConfig,
    note_map: NoteMap,
    counters: *SyncCounters,
) !void {
    const allocator = init.arena.allocator();
    const local_cards = try store.cards(allocator, note_map.local_deck_id);
    const remote_cards = try listRemoteCards(init, cloud, note_map.remote_deck_id);
    const content_store = storage.ContentStore.init(store);

    for (local_cards) |local_card| {
        const source = (try content_store.cardSource(allocator, local_card.id)) orelse continue;
        if (source.note_id != note_map.local_id) continue;
        const local_generation = generationFromKey(source.generation_key) catch continue;
        for (remote_cards) |remote_card| {
            const remote_note_id = remote_card.note_id orelse continue;
            if ((parseRemoteId(remote_note_id) catch continue) != note_map.remote_id) continue;
            const remote_generation = remote_card.generation orelse continue;
            if (!generationEqual(local_generation, remote_generation)) continue;
            try syncCardReviews(init, store, cloud, local_card.id, try parseRemoteId(remote_card.id), counters);
            break;
        }
    }
}

fn syncMappedNotes(
    init: std.process.Init,
    store: *storage.Store,
    cloud: CloudConfig,
    state: *SyncState,
    deck_map: DeckMap,
    counters: *SyncCounters,
) !void {
    const allocator = init.arena.allocator();
    const content_store = storage.ContentStore.init(store);
    const local_notes = try content_store.notesForDeck(allocator, deck_map.local_id);
    const remote_summaries = try listRemoteNotes(init, cloud, deck_map.remote_id);

    for (state.notes.items) |*mapping| {
        if (mapping.local_deck_id != deck_map.local_id or mapping.remote_deck_id != deck_map.remote_id) continue;
        var local_found: ?content.OwnedNote = null;
        for (local_notes) |entry| if (entry.note.id == mapping.local_id) {
            local_found = entry.note;
            break;
        };
        var remote_found = false;
        for (remote_summaries) |summary| if ((parseRemoteId(summary.id) catch continue) == mapping.remote_id) {
            remote_found = true;
            break;
        };

        if (local_found == null and !remote_found) continue;
        if (local_found == null and remote_found) {
            const path = try std.fmt.allocPrint(allocator, "/notes/{d}", .{mapping.remote_id});
            try requestVoid(init, cloud, .DELETE, path, null);
            continue;
        }
        if (local_found != null and !remote_found) {
            note_mutation.delete(allocator, store, mapping.local_deck_id, mapping.local_id, nowMs(init.io)) catch {};
            continue;
        }

        const local_note = local_found.?;
        const remote_note = try getRemoteNote(init, cloud, mapping.remote_id);
        const local_hash = try localNoteHash(allocator, local_note);
        const remote_hash = remoteNoteHash(remote_note);
        if (local_hash == remote_hash) {
            mapping.last_hash = local_hash;
        } else if (local_hash == mapping.last_hash) {
            try updateLocalNote(allocator, store, mapping.local_deck_id, mapping.local_id, remote_note);
            mapping.last_hash = remote_hash;
            counters.pulled_notes += 1;
        } else if (remote_hash == mapping.last_hash) {
            const updated = try updateRemoteNote(init, cloud, mapping.remote_id, local_note);
            mapping.last_hash = remoteNoteHash(updated);
            counters.pushed_notes += 1;
        } else {
            counters.conflicts += 1;
            continue;
        }
        try syncReviewsForNote(init, store, cloud, mapping.*, counters);
    }

    for (local_notes) |entry| {
        if (findNoteLocal(state, entry.note.id) != null) continue;
        const local_hash = try localNoteHash(allocator, entry.note);
        var matched_remote: ?RemoteNote = null;
        for (remote_summaries) |summary| {
            const remote_id = parseRemoteId(summary.id) catch continue;
            if (findNoteRemote(state, remote_id) != null) continue;
            const candidate = try getRemoteNote(init, cloud, remote_id);
            if (remoteNoteHash(candidate) == local_hash) {
                matched_remote = candidate;
                break;
            }
        }
        if (matched_remote) |remote_note| {
            const remote_id = try parseRemoteId(remote_note.id);
            try state.notes.append(allocator, .{
                .local_id = entry.note.id,
                .remote_id = remote_id,
                .local_deck_id = deck_map.local_id,
                .remote_deck_id = deck_map.remote_id,
                .last_hash = local_hash,
            });
            try syncReviewsForNote(init, store, cloud, state.notes.items[state.notes.items.len - 1], counters);
        }
    }

    for (local_notes) |entry| {
        if (findNoteLocal(state, entry.note.id) != null) continue;
        const remote = try createRemoteNote(init, cloud, deck_map.remote_id, entry.note);
        const remote_id = try parseRemoteId(remote.id);
        const hash = try localNoteHash(allocator, entry.note);
        try state.notes.append(allocator, .{
            .local_id = entry.note.id,
            .remote_id = remote_id,
            .local_deck_id = deck_map.local_id,
            .remote_deck_id = deck_map.remote_id,
            .last_hash = hash,
        });
        counters.pushed_notes += 1;
        try syncReviewsForNote(init, store, cloud, state.notes.items[state.notes.items.len - 1], counters);
    }

    for (remote_summaries) |summary| {
        const remote_id = parseRemoteId(summary.id) catch continue;
        if (findNoteRemote(state, remote_id) != null) continue;
        const remote = try getRemoteNote(init, cloud, remote_id);
        const local_id = try createLocalNote(allocator, store, deck_map.local_id, remote);
        const hash = remoteNoteHash(remote);
        try state.notes.append(allocator, .{
            .local_id = local_id,
            .remote_id = remote_id,
            .local_deck_id = deck_map.local_id,
            .remote_deck_id = deck_map.remote_id,
            .last_hash = hash,
        });
        counters.pulled_notes += 1;
        try syncReviewsForNote(init, store, cloud, state.notes.items[state.notes.items.len - 1], counters);
    }
}

fn adoptLegacyCards(allocator: Allocator, store: *storage.Store, deck_id: u64, now_ms: i64) !void {
    const cards = try store.cards(allocator, deck_id);
    const content_store = storage.ContentStore.init(store);
    for (cards) |card| {
        if (try content_store.cardSource(allocator, card.id) == null) {
            _ = try content_store.adoptLegacyCard(allocator, card.id, now_ms);
        }
    }
}

fn syncWithStore(
    init: std.process.Init,
    store: *storage.Store,
    cloud: CloudConfig,
) !SyncCounters {
    const allocator = init.arena.allocator();
    var state = try loadSyncState(init);
    var counters: SyncCounters = .{};
    const initial_remote_decks = try listRemoteDecks(init, cloud);
    const local_decks = try store.decks(allocator, nowMs(init.io));

    for (local_decks) |local| {
        if (findDeckLocal(&state, local.id) != null) continue;
        const local_hash = hashDeckName(local.name);
        for (initial_remote_decks) |remote| {
            const remote_id = parseRemoteId(remote.id) catch continue;
            if (findDeckRemote(&state, remote_id) != null) continue;
            if (hashDeckName(remote.name) != local_hash) continue;
            try state.decks.append(allocator, .{ .local_id = local.id, .remote_id = remote_id, .last_hash = local_hash });
            break;
        }
    }

    for (local_decks) |local| {
        if (findDeckLocal(&state, local.id) != null) continue;
        const remote = try createRemoteDeck(init, cloud, local.name);
        const remote_id = try parseRemoteId(remote.id);
        try state.decks.append(allocator, .{
            .local_id = local.id,
            .remote_id = remote_id,
            .last_hash = hashDeckName(local.name),
        });
        counters.pushed_decks += 1;
    }

    for (initial_remote_decks) |remote| {
        const remote_id = parseRemoteId(remote.id) catch continue;
        if (findDeckRemote(&state, remote_id) != null) continue;
        const local_id = try store.createDeck(remote.name, nowMs(init.io));
        _ = try store.ensureDefaultFsrs7(nowMs(init.io));
        try state.decks.append(allocator, .{
            .local_id = local_id,
            .remote_id = remote_id,
            .last_hash = hashDeckName(remote.name),
        });
        counters.pulled_decks += 1;
    }

    const remote_decks = try listRemoteDecks(init, cloud);
    for (state.decks.items) |*mapping| {
        const local = (try store.getDeck(allocator, mapping.local_id)) orelse continue;
        var remote_match: ?RemoteDeck = null;
        for (remote_decks) |remote| {
            if ((parseRemoteId(remote.id) catch continue) == mapping.remote_id) {
                remote_match = remote;
                break;
            }
        }
        if (remote_match == null) continue;
        const remote = remote_match.?;
        const local_hash = hashDeckName(local.name);
        const remote_hash = hashDeckName(remote.name);
        if (local_hash == remote_hash) {
            mapping.last_hash = local_hash;
        } else if (local_hash == mapping.last_hash) {
            try store.renameDeck(mapping.local_id, remote.name);
            mapping.last_hash = remote_hash;
        } else if (remote_hash == mapping.last_hash) {
            const updated = try renameRemoteDeck(init, cloud, mapping.remote_id, local.name);
            mapping.last_hash = hashDeckName(updated.name);
        } else {
            counters.conflicts += 1;
            continue;
        }

        try adoptLegacyCards(allocator, store, mapping.local_id, nowMs(init.io));
        try syncMappedNotes(init, store, cloud, &state, mapping.*, &counters);
    }

    try saveSyncState(init, &state);
    return counters;
}

fn syncCommand(init: std.process.Init) !void {
    const cloud = try loadCloudConfig(init);
    _ = try requestJson(CloudUser, init, cloud, .GET, "/auth/me", null);
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);
    const counters = switch (selection.backend) {
        .sqlite => blk: {
            const db_path_z = try arena.dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            break :blk try syncWithStore(init, &store, cloud);
        },
        .mongodb => blk: {
            const mongo = try storage.MongoStore.connect(init.io, allocator, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            break :blk try syncWithStore(init, &store, cloud);
        },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try out.print(
        "Synced with {s}.\n↑ {d} decks, {d} notes, {d} reviews\n↓ {d} decks, {d} notes, {d} reviews\n",
        .{
            cloud.base_url,
            counters.pushed_decks,
            counters.pushed_notes,
            counters.pushed_reviews,
            counters.pulled_decks,
            counters.pulled_notes,
            counters.pulled_reviews,
        },
    );
    if (counters.conflicts != 0) {
        try out.print("Conflicts: {d} (left unchanged; resolve on one side and run deez sync again)\n", .{counters.conflicts});
    }
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (!isCommand(args)) return error.InvalidArguments;
    if (std.mem.eql(u8, args[1], "login")) return login(init, args);
    if (std.mem.eql(u8, args[1], "whoami")) {
        if (args.len != 2) return error.InvalidArguments;
        return whoami(init);
    }
    if (std.mem.eql(u8, args[1], "logout")) {
        if (args.len != 2) return error.InvalidArguments;
        return logout(init);
    }
    if (std.mem.eql(u8, args[1], "sync")) {
        if (args.len != 2) return error.InvalidArguments;
        return syncCommand(init);
    }
    return error.InvalidArguments;
}

test "magic-link parser accepts raw tokens and full URLs" {
    const raw = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqualStrings(raw, try parseMagicToken(raw));
    const url = "https://deez.run/auth/magic?token=" ++ raw;
    try std.testing.expectEqualStrings(raw, try parseMagicToken(url));
}

test "generation parser ignores backend-specific note ids" {
    const parsed = try generationFromKey("note:42:cloze:3");
    try std.testing.expectEqualStrings("cloze", parsed.kind);
    try std.testing.expectEqual(@as(u32, 3), parsed.ordinal);
}
