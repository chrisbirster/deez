const std = @import("std");

const config = @import("config.zig");
const content = @import("content.zig");
const note_mutation = @import("note_mutation.zig");
const storage = @import("storage/root.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const cookie_name = "__Host-deez_session";
const max_http_body_bytes: usize = 16 * 1024 * 1024;

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

const RemoteDeck = struct {
    id: []const u8,
    name: []const u8,
};

const RemoteNoteSummary = struct {
    id: []const u8,
    deck_id: []const u8,
};

const RemoteNote = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    fields: []const []const u8,
    tags: []const []const u8,
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
    base_url: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    decks: []const DeckMap = &.{},
    notes: []const NoteMap = &.{},
};

const ScopeFile = struct {
    version: u32 = 1,
    base_url: []const u8,
    user_id: []const u8,
};

const RawResponse = struct {
    status: u16,
    body: []u8,
};

const DeckAction = enum { keep, drop, delete_local, delete_remote };
const NoteAction = enum { keep, drop, delete_local, delete_remote };

const PlannedDeck = struct {
    mapping: DeckMap,
    action: DeckAction,
};

const PlannedNote = struct {
    mapping: NoteMap,
    action: NoteAction,
};

pub const Result = struct {
    deleted_local_decks: usize = 0,
    deleted_remote_decks: usize = 0,
    deleted_local_notes: usize = 0,
    deleted_remote_notes: usize = 0,

    pub fn total(self: Result) usize {
        return self.deleted_local_decks + self.deleted_remote_decks + self.deleted_local_notes + self.deleted_remote_notes;
    }
};

pub fn isSyncCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "sync");
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

fn scopePath(allocator: Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez/sync-account.json", .{home_dir});
}

fn stringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn writePrivateFile(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    file.setPermissions(init.io, @enumFromInt(0o600)) catch {};
    try file.writeStreamingAll(init.io, bytes);
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

fn loadSyncState(init: std.process.Init) !PersistedSync {
    const allocator = init.arena.allocator();
    const path = try syncStatePath(allocator, try home(init));
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(PersistedSync, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn loadScope(init: std.process.Init) !?ScopeFile {
    const allocator = init.arena.allocator();
    const path = try scopePath(allocator, try home(init));
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(ScopeFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn writeScopedState(init: std.process.Init, state: PersistedSync, cloud: CloudConfig, user: CloudUser) !void {
    const allocator = init.arena.allocator();
    const dir = try configDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
    const scoped = PersistedSync{
        .version = 2,
        .base_url = cloud.base_url,
        .user_id = user.id,
        .decks = state.decks,
        .notes = state.notes,
    };
    const state_bytes = try stringifyAlloc(allocator, scoped);
    try writePrivateFile(init, try syncStatePath(allocator, try home(init)), state_bytes);
    const scope_bytes = try stringifyAlloc(allocator, ScopeFile{ .base_url = cloud.base_url, .user_id = user.id });
    try writePrivateFile(init, try scopePath(allocator, try home(init)), scope_bytes);
}

fn apiUrl(allocator: Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/v1{s}", .{ std.mem.trimEnd(u8, base_url, "/"), path });
}

fn httpRequest(init: std.process.Init, method: std.http.Method, url: []const u8, session: []const u8) !RawResponse {
    const allocator = init.arena.allocator();
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    const cookie = try std.fmt.allocPrint(allocator, "{s}={s}", .{ cookie_name, session });
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "deez-cli/1" },
        .{ .name = "Cookie", .value = cookie },
    };
    const uri = try std.Uri.parse(url);
    var request = try client.request(method, uri, .{ .extra_headers = &headers });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = try reader.allocRemaining(allocator, .limited(max_http_body_bytes));
    return .{ .status = status, .body = body };
}

fn requestJson(comptime T: type, init: std.process.Init, cloud: CloudConfig, path: []const u8) !T {
    const response = try httpRequest(init, .GET, try apiUrl(init.arena.allocator(), cloud.base_url, path), cloud.session);
    if (response.status < 200 or response.status >= 300) return error.CloudRequestFailed;
    const parsed = try std.json.parseFromSlice(T, init.arena.allocator(), response.body, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn requestDelete(init: std.process.Init, cloud: CloudConfig, path: []const u8) !void {
    const response = try httpRequest(init, .DELETE, try apiUrl(init.arena.allocator(), cloud.base_url, path), cloud.session);
    if (response.status < 200 or response.status >= 300) return error.CloudRequestFailed;
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

fn remoteDeckById(decks: []const RemoteDeck, id: u64) ?RemoteDeck {
    for (decks) |deck| if ((parseRemoteId(deck.id) catch continue) == id) return deck;
    return null;
}

fn remoteNoteExists(summaries: []const RemoteNoteSummary, id: u64) bool {
    for (summaries) |summary| if ((parseRemoteId(summary.id) catch continue) == id) return true;
    return false;
}

fn scopeMatches(base_url: []const u8, user_id: []const u8, scoped_base: []const u8, scoped_user: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, base_url, "/"), std.mem.trimEnd(u8, scoped_base, "/")) and std.mem.eql(u8, user_id, scoped_user);
}

fn verifyScope(init: std.process.Init, cloud: CloudConfig, user: CloudUser, state: PersistedSync, remote_decks: []const RemoteDeck) !void {
    if (try loadScope(init)) |scope| {
        if (!scopeMatches(cloud.base_url, user.id, scope.base_url, scope.user_id)) return error.SyncAccountMismatch;
    }
    if (state.base_url != null or state.user_id != null) {
        if (state.base_url == null or state.user_id == null) return error.InvalidSyncState;
        if (!scopeMatches(cloud.base_url, user.id, state.base_url.?, state.user_id.?)) return error.SyncAccountMismatch;
        return;
    }

    // One-time migration of the rc.4 unscoped map: only adopt it when every
    // mapped remote deck is actually visible to the currently authenticated
    // account. This prevents silently reusing another account's numeric ids.
    for (state.decks) |mapping| {
        if (remoteDeckById(remote_decks, mapping.remote_id) == null) return error.SyncAccountMismatch;
    }
}

fn decideDeletion(local_exists: bool, remote_exists: bool, local_hash: ?u64, remote_hash: ?u64, last_hash: u64) !u8 {
    if (local_exists and remote_exists) return 0;
    if (!local_exists and !remote_exists) return 1;
    if (!local_exists) {
        if (remote_hash.? != last_hash) return error.SyncDeletionConflict;
        return 2;
    }
    if (local_hash.? != last_hash) return error.SyncDeletionConflict;
    return 3;
}

fn reconcileWithStore(init: std.process.Init, store: *storage.Store, cloud: CloudConfig, user: CloudUser) !Result {
    const allocator = init.arena.allocator();
    const state = try loadSyncState(init);
    const remote_decks = try requestJson([]const RemoteDeck, init, cloud, "/decks");
    try verifyScope(init, cloud, user, state, remote_decks);

    var planned_decks: std.ArrayList(PlannedDeck) = .empty;
    var planned_notes: std.ArrayList(PlannedNote) = .empty;

    for (state.decks) |mapping| {
        const local = try store.getDeck(allocator, mapping.local_id);
        const remote = remoteDeckById(remote_decks, mapping.remote_id);
        const decision = try decideDeletion(
            local != null,
            remote != null,
            if (local) |deck| hashDeckName(deck.name) else null,
            if (remote) |deck| hashDeckName(deck.name) else null,
            mapping.last_hash,
        );
        const action: DeckAction = switch (decision) {
            0 => .keep,
            1 => .drop,
            2 => .delete_remote,
            3 => .delete_local,
            else => unreachable,
        };
        try planned_decks.append(allocator, .{ .mapping = mapping, .action = action });
    }

    const content_store = storage.ContentStore.init(store);
    for (state.notes) |mapping| {
        var parent_kept = false;
        for (planned_decks.items) |deck| {
            if (deck.mapping.local_id == mapping.local_deck_id and deck.mapping.remote_id == mapping.remote_deck_id) {
                parent_kept = deck.action == .keep;
                break;
            }
        }
        if (!parent_kept) {
            try planned_notes.append(allocator, .{ .mapping = mapping, .action = .drop });
            continue;
        }

        const local = try content_store.getNote(allocator, mapping.local_id);
        const notes_path = try std.fmt.allocPrint(allocator, "/decks/{d}/notes", .{mapping.remote_deck_id});
        const remote_summaries = try requestJson([]const RemoteNoteSummary, init, cloud, notes_path);
        const remote_exists = remoteNoteExists(remote_summaries, mapping.remote_id);
        var remote_hash: ?u64 = null;
        if (remote_exists) {
            const note_path = try std.fmt.allocPrint(allocator, "/notes/{d}", .{mapping.remote_id});
            const remote = try requestJson(RemoteNote, init, cloud, note_path);
            remote_hash = remoteNoteHash(remote);
        }
        const decision = try decideDeletion(
            local != null,
            remote_exists,
            if (local) |note| try localNoteHash(allocator, note) else null,
            remote_hash,
            mapping.last_hash,
        );
        const action: NoteAction = switch (decision) {
            0 => .keep,
            1 => .drop,
            2 => .delete_remote,
            3 => .delete_local,
            else => unreachable,
        };
        try planned_notes.append(allocator, .{ .mapping = mapping, .action = action });
    }

    // The two loops above are a complete preflight. If an edited-vs-deleted
    // conflict exists, no deletion has happened yet and this function exits.
    var result: Result = .{};
    for (planned_notes.items) |planned| switch (planned.action) {
        .delete_remote => {
            const path = try std.fmt.allocPrint(allocator, "/notes/{d}", .{planned.mapping.remote_id});
            try requestDelete(init, cloud, path);
            result.deleted_remote_notes += 1;
        },
        .delete_local => {
            try note_mutation.delete(allocator, store, planned.mapping.local_deck_id, planned.mapping.local_id, Io.Timestamp.now(init.io, .real).toSeconds() * 1_000);
            result.deleted_local_notes += 1;
        },
        else => {},
    };

    for (planned_decks.items) |planned| switch (planned.action) {
        .delete_remote => {
            const path = try std.fmt.allocPrint(allocator, "/decks/{d}", .{planned.mapping.remote_id});
            try requestDelete(init, cloud, path);
            result.deleted_remote_decks += 1;
        },
        .delete_local => {
            try store.deleteDeck(planned.mapping.local_id);
            result.deleted_local_decks += 1;
        },
        else => {},
    };

    var kept_decks: std.ArrayList(DeckMap) = .empty;
    for (planned_decks.items) |planned| if (planned.action == .keep) try kept_decks.append(allocator, planned.mapping);
    var kept_notes: std.ArrayList(NoteMap) = .empty;
    for (planned_notes.items) |planned| if (planned.action == .keep) try kept_notes.append(allocator, planned.mapping);

    try writeScopedState(init, .{
        .version = 2,
        .base_url = cloud.base_url,
        .user_id = user.id,
        .decks = kept_decks.items,
        .notes = kept_notes.items,
    }, cloud, user);
    return result;
}

pub fn prepare(init: std.process.Init) !Result {
    const cloud = try loadCloudConfig(init);
    const user = try requestJson(CloudUser, init, cloud, "/auth/me");
    const selection = try config.resolve(init);
    return switch (selection.backend) {
        .sqlite => blk: {
            const path = try init.arena.allocator().dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(path);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            break :blk try reconcileWithStore(init, &store, cloud, user);
        },
        .mongodb => blk: {
            const mongo = try storage.MongoStore.connect(init.io, init.gpa, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            break :blk try reconcileWithStore(init, &store, cloud, user);
        },
    };
}

pub fn seal(init: std.process.Init) !void {
    const cloud = try loadCloudConfig(init);
    const user = try requestJson(CloudUser, init, cloud, "/auth/me");
    const state = try loadSyncState(init);
    try writeScopedState(init, state, cloud, user);
}

test "scope comparison normalizes only trailing slashes" {
    try std.testing.expect(scopeMatches("https://deez.run/", "u1", "https://deez.run", "u1"));
    try std.testing.expect(!scopeMatches("https://deez.run", "u1", "https://deez.run", "u2"));
    try std.testing.expect(!scopeMatches("https://other.example", "u1", "https://deez.run", "u1"));
}

test "deletion decision is idempotent and conflicts on edited survivor" {
    try std.testing.expectEqual(@as(u8, 0), try decideDeletion(true, true, 10, 10, 10));
    try std.testing.expectEqual(@as(u8, 1), try decideDeletion(false, false, null, null, 10));
    try std.testing.expectEqual(@as(u8, 2), try decideDeletion(false, true, null, 10, 10));
    try std.testing.expectEqual(@as(u8, 3), try decideDeletion(true, false, 10, null, 10));
    try std.testing.expectError(error.SyncDeletionConflict, decideDeletion(false, true, null, 11, 10));
    try std.testing.expectError(error.SyncDeletionConflict, decideDeletion(true, false, 11, null, 10));
}
