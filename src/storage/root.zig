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
    var error_message: [*sqlite.c]u8 = null;
    const result = sqlite.c.sqlite3_exec(db.handle, sql.ptr, null, null, &error_message);
    if (error_message != null) sqlite.c.sqlite3_free(error_message);
    if (result != sqlite.c.SQLITE_OK) return error.SqliteIndexSetupFailed;
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
        .mongodb => {},
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

test {
    std.testing.refAllDecls(@This());
}
