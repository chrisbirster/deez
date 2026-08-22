const std = @import("std");

const content = @import("../content.zig");
const store_mod = @import("store.zig");
const sqlite_content = @import("sqlite_content.zig");
const mongodb_content = @import("mongodb_content.zig");

pub const ContentStore = struct {
    store: *store_mod.Store,

    pub fn init(store: *store_mod.Store) ContentStore {
        return .{ .store = store };
    }

    pub fn ensureBuiltInBasic(self: ContentStore, created_at_ms: i64) !content.NoteTypeId {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.ensureBuiltInBasic(db, created_at_ms),
            .mongodb => |*mongo| mongodb_content.ensureBuiltInBasic(mongo, created_at_ms),
        };
    }

    pub fn createNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        note_type_id: content.NoteTypeId,
        fields: []const content.FieldValue,
        tags_json: []const u8,
        created_at_ms: i64,
    ) !content.NoteId {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.createNote(db, note_type_id, fields, tags_json, created_at_ms),
            .mongodb => |*mongo| mongodb_content.createNote(allocator, mongo, note_type_id, fields, tags_json, created_at_ms),
        };
    }

    pub fn createBasicNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        deck_id: u64,
        front: []const u8,
        back: []const u8,
        tags_json: []const u8,
        created_at_ms: i64,
    ) !content.CreatedNote {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.createBasicNote(allocator, db, deck_id, front, back, tags_json, created_at_ms),
            .mongodb => |*mongo| mongodb_content.createBasicNote(allocator, mongo, deck_id, front, back, tags_json, created_at_ms),
        };
    }

    pub fn adoptLegacyCard(
        self: ContentStore,
        allocator: std.mem.Allocator,
        card_id: u64,
        adopted_at_ms: i64,
    ) !content.NoteId {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.adoptLegacyCard(allocator, db, card_id, adopted_at_ms),
            .mongodb => |*mongo| mongodb_content.adoptLegacyCard(allocator, mongo, card_id, adopted_at_ms),
        };
    }

    pub fn getNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        note_id: content.NoteId,
    ) !?content.OwnedNote {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.getNote(allocator, db, note_id),
            .mongodb => |*mongo| mongodb_content.getNote(allocator, mongo, note_id),
        };
    }

    pub fn cardSource(
        self: ContentStore,
        allocator: std.mem.Allocator,
        card_id: u64,
    ) !?content.GeneratedCardSource {
        return switch (self.store.*) {
            .sqlite => |db| sqlite_content.cardSource(allocator, db, card_id),
            .mongodb => |*mongo| mongodb_content.cardSource(allocator, mongo, card_id),
        };
    }
};

test "ContentStore adopts an existing SQLite card without changing its id" {
    const sqlite = @import("sqlite.zig");
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: store_mod.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("legacy", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    const content_store = ContentStore.init(&store);
    const note_id = try content_store.adoptLegacyCard(std.testing.allocator, card_id, 1);
    const source = (try content_store.cardSource(std.testing.allocator, card_id)).?;
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqual(note_id, source.note_id);
    try std.testing.expectEqual(card_id, @as(u64, card_id));
}
