const std = @import("std");
const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");
const sqlite = @import("sqlite.zig");
const sqlite_cards = @import("sqlite_cards.zig");
const catalog_mod = @import("catalog.zig");
const report_mod = @import("report.zig");
const mongodb = @import("mongodb.zig");
const mongodb_cards = @import("mongodb_cards.zig");

const Allocator = std.mem.Allocator;

/// Deez persistence boundary.
///
/// This is deliberately an operation-oriented tagged union rather than a
/// generic database/query API. SQLite is free to use normalized tables and SQL;
/// MongoDB is free to use Mongo-native embedded documents and indexes.
pub const Store = union(enum) {
    sqlite: *sqlite.Db,
    mongodb: mongodb.Store,

    pub fn deinit(self: *Store) void {
        switch (self.*) {
            .sqlite => {}, // the caller owns the SQLite Db lifetime
            .mongodb => |*store| store.deinit(),
        }
        self.* = undefined;
    }

    pub fn createDeck(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.DeckId {
        return switch (self.*) {
            .sqlite => |db| db.createDeck(name, created_at_ms),
            .mongodb => |*store| store.createDeck(name, created_at_ms),
        };
    }

    pub fn getDeck(
        self: *Store,
        allocator: Allocator,
        id: card_mod.DeckId,
    ) !?sqlite.OwnedDeck {
        return switch (self.*) {
            .sqlite => |db| db.getDeck(allocator, id),
            .mongodb => |*store| store.getDeck(allocator, id),
        };
    }

    pub fn renameDeck(self: *Store, id: card_mod.DeckId, name: []const u8) !void {
        switch (self.*) {
            .sqlite => |db| try db.renameDeck(id, name),
            .mongodb => |*store| try store.renameDeck(id, name),
        }
    }

    pub fn deleteDeck(self: *Store, id: card_mod.DeckId) !void {
        switch (self.*) {
            .sqlite => |db| try db.deleteDeck(id),
            .mongodb => |*store| try store.deleteDeck(id),
        }
    }

    pub fn createCard(
        self: *Store,
        deck_id: card_mod.DeckId,
        question: []const u8,
        answer: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.CardId {
        return switch (self.*) {
            .sqlite => |db| db.createCard(deck_id, question, answer, created_at_ms),
            .mongodb => |*store| store.createCard(deck_id, question, answer, created_at_ms),
        };
    }

    pub fn getCard(
        self: *Store,
        allocator: Allocator,
        id: card_mod.CardId,
    ) !?sqlite.OwnedCard {
        return switch (self.*) {
            .sqlite => |db| db.getCard(allocator, id),
            .mongodb => |*store| store.getCard(allocator, id),
        };
    }

    pub fn cards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
    ) ![]sqlite.OwnedCard {
        return switch (self.*) {
            .sqlite => |db| sqlite_cards.list(db, allocator, deck_id),
            .mongodb => |*store| mongodb_cards.list(store, allocator, deck_id),
        };
    }

    pub fn updateCard(
        self: *Store,
        id: card_mod.CardId,
        question: []const u8,
        answer: []const u8,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try db.updateCard(id, question, answer),
            .mongodb => |*store| try store.updateCard(id, question, answer),
        }
    }

    pub fn deleteCard(self: *Store, id: card_mod.CardId) !void {
        switch (self.*) {
            .sqlite => |db| try db.deleteCard(id),
            .mongodb => |*store| try store.deleteCard(id),
        }
    }

    pub fn loadHistory(
        self: *Store,
        allocator: Allocator,
        card_id: card_mod.CardId,
    ) ![]fsrs.HistoryEntry {
        return switch (self.*) {
            .sqlite => |db| db.loadHistory(allocator, card_id),
            .mongodb => |*store| store.loadHistory(allocator, card_id),
        };
    }

    pub fn putFsrs7Parameters(
        self: *Store,
        parameters: fsrs.v7.Parameters,
        source: []const u8,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).putFsrs7Parameters(
                parameters,
                source,
                created_at_ms,
            ),
            .mongodb => |*store| store.putFsrs7Parameters(parameters, source, created_at_ms),
        };
    }

    pub fn loadFsrs7Parameters(
        self: *Store,
        id: fsrs.ParameterSetId,
    ) !fsrs.v7.Parameters {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).loadFsrs7Parameters(id),
            .mongodb => |*store| store.loadFsrs7Parameters(id),
        };
    }

    pub fn ensureDefaultFsrs7(
        self: *Store,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).ensureDefaultFsrs7(created_at_ms),
            .mongodb => |*store| store.ensureDefaultFsrs7(created_at_ms),
        };
    }

    pub fn resolveDeckScheduler(
        self: *Store,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
    ) !catalog_mod.ResolvedScheduler {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).resolveDeckScheduler(deck_id, now_ms),
            .mongodb => |*store| store.resolveDeckScheduler(deck_id, now_ms),
        };
    }

    pub fn setGlobalFsrs7(self: *Store, parameter_set_id: fsrs.ParameterSetId) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setGlobalFsrs7(parameter_set_id),
            .mongodb => |*store| try store.setGlobalFsrs7(parameter_set_id),
        }
    }

    pub fn setDeckFsrs7(
        self: *Store,
        deck_id: card_mod.DeckId,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setDeckFsrs7(deck_id, parameter_set_id),
            .mongodb => |*store| try store.setDeckFsrs7(deck_id, parameter_set_id),
        }
    }

    pub fn createGroup(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !u64 {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).createGroup(name, created_at_ms),
            .mongodb => |*store| store.createGroup(name, created_at_ms),
        };
    }

    pub fn assignDeckGroup(
        self: *Store,
        deck_id: card_mod.DeckId,
        group_id: ?u64,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).assignDeckGroup(deck_id, group_id),
            .mongodb => |*store| try store.assignDeckGroup(deck_id, group_id),
        }
    }

    pub fn inheritDeckScheduler(self: *Store, deck_id: card_mod.DeckId) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).inheritDeckScheduler(deck_id),
            .mongodb => |*store| try store.inheritDeckScheduler(deck_id),
        }
    }

    pub fn setGroupFsrs7(
        self: *Store,
        group_id: u64,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setGroupFsrs7(group_id, parameter_set_id),
            .mongodb => |*store| try store.setGroupFsrs7(group_id, parameter_set_id),
        }
    }

    pub fn recordReviewAndState(
        self: *Store,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        state: catalog_mod.SchedulerState,
        scheduled_at_ms: time.TimestampMs,
    ) !u64 {
        return switch (self.*) {
            .sqlite => |db| blk: {
                const catalog: catalog_mod.Catalog = .{ .db = db };
                try db.beginImmediate();
                errdefer db.rollback();
                const review_id = try catalog.appendReview(
                    card_id,
                    rating,
                    reviewed_at_ms,
                    state.stamp,
                    scheduled_at_ms,
                );
                try catalog.upsertSchedulerState(state);
                try db.commit();
                break :blk review_id;
            },
            .mongodb => |*store| store.recordReviewAndState(
                card_id,
                rating,
                reviewed_at_ms,
                state,
                scheduled_at_ms,
            ),
        };
    }

    pub fn upsertSchedulerState(self: *Store, state: catalog_mod.SchedulerState) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).upsertSchedulerState(state),
            .mongodb => |*store| try store.upsertSchedulerState(state),
        }
    }

    pub fn clearSchedulerState(self: *Store, card_id: card_mod.CardId) !void {
        switch (self.*) {
            .sqlite => |db| try db.clearSchedulerState(card_id),
            .mongodb => |*store| try store.clearSchedulerState(card_id),
        }
    }

    pub fn getSchedulerState(
        self: *Store,
        card_id: card_mod.CardId,
    ) !?catalog_mod.SchedulerState {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).getSchedulerState(card_id),
            .mongodb => |*store| store.getSchedulerState(card_id),
        };
    }

    pub fn dueCards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]catalog_mod.OwnedDueCard {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).dueCards(allocator, deck_id, now_ms, limit),
            .mongodb => |*store| store.dueCards(allocator, deck_id, now_ms, limit),
        };
    }

    pub fn decks(
        self: *Store,
        allocator: Allocator,
        now_ms: time.TimestampMs,
    ) ![]report_mod.DeckSummary {
        return switch (self.*) {
            .sqlite => |db| (report_mod.Report{ .db = db }).decks(allocator, now_ms),
            .mongodb => |*store| store.decks(allocator, now_ms),
        };
    }

    pub fn stats(
        self: *Store,
        now_ms: time.TimestampMs,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.Stats {
        return switch (self.*) {
            .sqlite => |db| (report_mod.Report{ .db = db }).stats(now_ms, deck_id),
            .mongodb => |*store| store.stats(now_ms, deck_id),
        };
    }

    pub fn histories(
        self: *Store,
        allocator: Allocator,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.OwnedHistories {
        return switch (self.*) {
            .sqlite => |db| (report_mod.Report{ .db = db }).histories(allocator, deck_id),
            .mongodb => |*store| store.histories(allocator, deck_id),
        };
    }
};

test "SQLite remains usable through Store" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("zig", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const card = (try store.getCard(std.testing.allocator, card_id)).?;
    defer card.deinit(std.testing.allocator);
    try std.testing.expectEqual(deck_id, card.deck_id);
}
