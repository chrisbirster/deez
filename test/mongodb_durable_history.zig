const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

fn connectStore() !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        replica_uri,
    );
    return .{ .mongodb = mongo };
}

test "MongoStore rejects invalid review targets without appending orphan history" {
    var store = try connectStore();
    defer store.deinit();

    const parameter_set_id = try store.ensureDefaultFsrs7(0);
    const missing_card_id: deez.CardId = 9_223_372_036;
    const state: deez.storage.SchedulerState = .{
        .card_id = missing_card_id,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = parameter_set_id,
        },
        .stability_days = 1.0,
        .difficulty = 5.0,
        .due_at_ms = 1_000,
        .last_reviewed_at_ms = 0,
    };

    try std.testing.expectError(
        error.CardNotFound,
        store.recordReviewAndState(
            missing_card_id,
            .good,
            0,
            state,
            1_000,
        ),
    );

    const history = try store.loadHistory(std.testing.allocator, missing_card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 0), history.len);
}

test "MongoStore rejects scheduler state for a different card" {
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-state-card-match", 0);
    defer store.deleteDeck(deck_id) catch {};
    const first = try store.createCard(deck_id, "first", "1", 0);
    const second = try store.createCard(deck_id, "second", "2", 0);
    const parameter_set_id = try store.ensureDefaultFsrs7(0);

    const wrong_state: deez.storage.SchedulerState = .{
        .card_id = second,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = parameter_set_id,
        },
        .stability_days = 1.0,
        .difficulty = 5.0,
        .due_at_ms = 1_000,
        .last_reviewed_at_ms = 0,
    };

    try std.testing.expectError(
        error.InvalidSchedulerState,
        store.recordReviewAndState(first, .good, 0, wrong_state, 1_000),
    );

    const history = try store.loadHistory(std.testing.allocator, first);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 0), history.len);
}
