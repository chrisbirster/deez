const std = @import("std");

pub const schema = @import("schema.zig");
pub const sqlite = @import("sqlite.zig");
pub const mongodb = @import("mongodb.zig");
pub const store = @import("store.zig");
pub const card_lifecycle = @import("card_lifecycle.zig");
pub const sqlite_content = @import("sqlite_content.zig");
pub const mongodb_content = @import("mongodb_content.zig");
pub const content_store = @import("content_store.zig");
pub const content_membership = @import("content_membership.zig");
pub const note_type_store = @import("note_type_store.zig");
pub const generated_card_store = @import("generated_card_store.zig");
pub const catalog = @import("catalog.zig");
pub const report = @import("report.zig");
pub const history_report = @import("history_report.zig");
pub const backup = @import("backup.zig");
pub const recovery = @import("recovery.zig");
pub const migration_commit = @import("migration_commit.zig");

const c = sqlite.c;

pub const Db = sqlite.Db;
pub const Store = store.Store;
pub const ContentStore = content_store.ContentStore;
pub const ContentMembership = content_membership.ContentMembership;
pub const MongoStore = mongodb.Store;
pub const OwnedDeck = sqlite.OwnedDeck;
pub const OwnedCard = sqlite.OwnedCard;
pub const ParameterSetRecord = sqlite.ParameterSetRecord;
pub const SchedulerStateRecord = sqlite.SchedulerStateRecord;
pub const Catalog = catalog.Catalog;
pub const ResolvedScheduler = catalog.ResolvedScheduler;
pub const OwnedDueCard = catalog.OwnedDueCard;
pub const SchedulerState = catalog.SchedulerState;
pub const Report = report.Report;
pub const DeckSummary = report.DeckSummary;
pub const Stats = report.Stats;
pub const OwnedHistories = report.OwnedHistories;
pub const HistoricalStats = history_report.HistoricalStats;

pub const IntegrityResult = recovery.IntegrityResult;

fn ensureSqliteAnalyticsIndexes(db: *Db) !void {
    const sql = "CREATE INDEX IF NOT EXISTS reviews_time_card_rating_idx ON reviews(reviewed_at_ms, card_id, rating);";
    var error_message: [*c]u8 = null;
    const result = c.sqlite3_exec(db.handle, sql.ptr, null, null, &error_message);
    if (error_message != null) c.sqlite3_free(error_message);
    if (result != c.SQLITE_OK) return error.SqliteIndexSetupFailed;
}

fn ensureMongoAnalyticsIndexes(mongo: *MongoStore) !void {
    try mongo.client.createIndex(
        mongo.client.databaseName(),
        "reviews",
        .{
            .reviewed_at_ms = @as(i32, 1),
            .card_id = @as(i32, 1),
            .rating = @as(i32, 1),
        },
        "review_time_card_rating",
        .{},
    );
}

pub fn historicalStats(
    allocator: std.mem.Allocator,
    storage_store: *Store,
    deck_id: ?u64,
    start_ms: ?i64,
    end_ms_exclusive: i64,
) !HistoricalStats {
    switch (storage_store.*) {
        .sqlite => |db| try ensureSqliteAnalyticsIndexes(db),
        .mongodb => |*mongo| try ensureMongoAnalyticsIndexes(mongo),
    }
    const owned = try storage_store.histories(allocator, deck_id);
    defer owned.deinit(allocator);
    const views = try allocator.alloc([]const @import("../fsrs/root.zig").HistoryEntry, owned.histories.len);
    defer allocator.free(views);
    for (owned.histories, 0..) |history, index| views[index] = history;
    return history_report.calculate(allocator, views, start_ms, end_ms_exclusive);
}

pub fn checkIntegrity(allocator: std.mem.Allocator, db: *Db) !IntegrityResult {
    return recovery.check(allocator, db);
}

test "historical stats recreates SQLite analytics index for an existing database" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var error_message: [*c]u8 = null;
    const drop_sql = "DROP INDEX IF EXISTS reviews_time_card_rating_idx;";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db.handle, drop_sql.ptr, null, null, &error_message));
    if (error_message != null) c.sqlite3_free(error_message);

    const deck_id = try db.createDeck("history-index", 0);
    const card_id = try db.createCard(deck_id, "q", "a", 0);
    _ = try db.appendReview(card_id, .good, 1, null, null);
    var storage_store: Store = .{ .sqlite = &db };
    _ = try historicalStats(std.testing.allocator, &storage_store, null, null, 2);

    var stmt: ?*c.sqlite3_stmt = null;
    const query = "SELECT 1 FROM sqlite_master WHERE type='index' AND name='reviews_time_card_rating_idx';";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.handle, query.ptr, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
}

test {
    std.testing.refAllDecls(@This());
}
