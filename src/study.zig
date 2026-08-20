const std = @import("std");
const card_mod = @import("card.zig");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const Preview = struct {
    card_id: card_mod.CardId,
    algorithm: fsrs.AlgorithmId,
    parameter_set_id: fsrs.ParameterSetId,
    schedule: fsrs.Schedule,
    retrievability: ?f64,
};

pub const ReviewResult = struct {
    review_id: u64,
    candidate: fsrs.Candidate,
    state: storage.SchedulerState,
};

pub const Study = struct {
    store: *storage.Store,

    pub fn init(store: *storage.Store) Study {
        return .{ .store = store };
    }

    fn fsrs7ForDeck(self: Study, deck_id: card_mod.DeckId, now_ms: time.TimestampMs) !struct {
        resolved: storage.ResolvedScheduler,
        parameters: fsrs.v7.Parameters,
        engine: fsrs.v7.Engine,
    } {
        const resolved = try self.store.resolveDeckScheduler(deck_id, now_ms);
        if (!resolved.algorithm.eql(.fsrs7)) return error.UnsupportedAlgorithm;
        const parameters = try self.store.loadFsrs7Parameters(resolved.parameter_set_id);
        return .{
            .resolved = resolved,
            .parameters = parameters,
            .engine = try fsrs.v7.Engine.init(parameters),
        };
    }

    pub fn preview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        now_ms: time.TimestampMs,
    ) !Preview {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, now_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);

        const schedule = try scheduler.engine.schedule(history, now_ms);
        const replayed = try scheduler.engine.replay(history);
        const retrievability = if (replayed) |state| blk: {
            if (now_ms < state.last_reviewed_at_ms) return error.NowBeforeLastReview;
            const elapsed_days = time.millisecondsToDays(now_ms - state.last_reviewed_at_ms);
            break :blk try fsrs.v7.model.retrievability(elapsed_days, state.memory, scheduler.parameters);
        } else null;

        return .{
            .card_id = card_id,
            .algorithm = scheduler.resolved.algorithm,
            .parameter_set_id = scheduler.resolved.parameter_set_id,
            .schedule = schedule,
            .retrievability = retrievability,
        };
    }

    fn stateAfterReview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        history: []const fsrs.HistoryEntry,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        scheduler: anytype,
        due_at_ms: time.TimestampMs,
    ) !storage.SchedulerState {
        _ = self;
        const combined = try allocator.alloc(fsrs.HistoryEntry, history.len + 1);
        defer allocator.free(combined);
        @memcpy(combined[0..history.len], history);
        combined[history.len] = .{ .rating = rating, .reviewed_at_ms = reviewed_at_ms };
        const replayed = (try scheduler.engine.replay(combined)) orelse return error.MissingReplayState;
        return .{
            .card_id = card_id,
            .stamp = .{
                .algorithm = scheduler.resolved.algorithm,
                .implementation = .current,
                .parameter_set_id = scheduler.resolved.parameter_set_id,
            },
            .stability_days = replayed.memory.stability_days,
            .difficulty = replayed.memory.difficulty,
            .due_at_ms = due_at_ms,
            .last_reviewed_at_ms = reviewed_at_ms,
        };
    }

    pub fn recordReview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
    ) !ReviewResult {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, reviewed_at_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);

        const schedule = try scheduler.engine.schedule(history, reviewed_at_ms);
        const candidate = schedule.forRating(rating);
        const state = try self.stateAfterReview(
            allocator,
            card_id,
            history,
            rating,
            reviewed_at_ms,
            scheduler,
            candidate.due_at_ms,
        );

        const review_id = try self.store.recordReviewAndState(
            card_id,
            rating,
            reviewed_at_ms,
            state,
            candidate.due_at_ms,
        );

        return .{
            .review_id = review_id,
            .candidate = candidate,
            .state = state,
        };
    }

    pub fn rebuildCardState(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        now_ms: time.TimestampMs,
    ) !?storage.SchedulerState {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, now_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        if (history.len == 0) {
            try self.store.clearSchedulerState(card_id);
            return null;
        }

        const replayed = (try scheduler.engine.replay(history)) orelse return error.MissingReplayState;
        const interval_days = try fsrs.v7.model.intervalForRetention(
            replayed.memory.stability_days,
            scheduler.parameters.desired_retention,
            scheduler.parameters,
        );
        const due_at_ms = replayed.last_reviewed_at_ms + time.daysToMilliseconds(interval_days);
        const state: storage.SchedulerState = .{
            .card_id = card_id,
            .stamp = .{
                .algorithm = scheduler.resolved.algorithm,
                .implementation = .current,
                .parameter_set_id = scheduler.resolved.parameter_set_id,
            },
            .stability_days = replayed.memory.stability_days,
            .difficulty = replayed.memory.difficulty,
            .due_at_ms = due_at_ms,
            .last_reviewed_at_ms = replayed.last_reviewed_at_ms,
        };
        try self.store.upsertSchedulerState(state);
        return state;
    }

    pub fn dueCards(
        self: Study,
        allocator: std.mem.Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]storage.OwnedDueCard {
        return self.store.dueCards(allocator, deck_id, now_ms, limit);
    }
};

test "recorded review updates immutable history and derived state" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("bson", 0);
    const card_id = try store.createCard(deck_id, "What is a byte?", "8 bits", 0);

    const result = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    try std.testing.expect(result.candidate.due_at_ms > 0);
    const history = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(fsrs.Rating.good, history[0].rating);

    const stored = (try store.getSchedulerState(card_id)).?;
    try std.testing.expectApproxEqAbs(result.state.stability_days.?, stored.stability_days.?, 1e-12);
    try std.testing.expectEqual(result.state.due_at_ms, stored.due_at_ms);
}

test "derived state rebuilds deterministically from history" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("zig", 0);
    const card_id = try store.createCard(deck_id, "What is comptime?", "Compile-time evaluation", 0);
    const day = time.milliseconds_per_day;
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    _ = try study.recordReview(std.testing.allocator, card_id, .hard, 2 * day);

    const before = (try store.getSchedulerState(card_id)).?;
    try store.clearSchedulerState(card_id);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);
    const rebuilt = (try study.rebuildCardState(std.testing.allocator, card_id, 2 * day)).?;
    try std.testing.expectApproxEqAbs(before.stability_days.?, rebuilt.stability_days.?, 1e-12);
    try std.testing.expectApproxEqAbs(before.difficulty.?, rebuilt.difficulty.?, 1e-12);
    try std.testing.expectEqual(before.due_at_ms, rebuilt.due_at_ms);
}
