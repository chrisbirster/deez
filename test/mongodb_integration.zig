const std = @import("std");
const deez = @import("deez");

test "MongoStore supports Deez study workflow with transactions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const mongo = try deez.storage.MongoStore.connect(
        io,
        allocator,
        "mongodb://localhost:27019/deez_integration?replicaSet=rs0",
    );
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    try std.testing.expect(store.mongodb.client.supports_sessions);
    try std.testing.expect(store.mongodb.client.supports_transactions);

    const deck_id = try store.createDeck("mongo-integration", 0);
    defer store.deleteDeck(deck_id) catch {};

    _ = try store.ensureDefaultFsrs7(0);
    const card_id = try store.createCard(
        deck_id,
        "What is BSON?",
        "Binary JSON",
        0,
    );

    const study = deez.Study.init(&store);
    const result = try study.recordReview(
        allocator,
        card_id,
        .good,
        deez.time.milliseconds_per_day,
    );

    const history = try store.loadHistory(allocator, card_id);
    defer allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(deez.fsrs.Rating.good, history[0].rating);

    const state = (try store.getSchedulerState(card_id)) orelse
        return error.MissingSchedulerState;
    try std.testing.expectEqual(result.state.due_at_ms, state.due_at_ms);
    try std.testing.expectApproxEqAbs(
        result.state.stability_days.?,
        state.stability_days.?,
        1e-12,
    );

    const due = try store.dueCards(
        allocator,
        deck_id,
        result.candidate.due_at_ms,
        10,
    );
    defer {
        for (due) |card| card.deinit(allocator);
        allocator.free(due);
    }
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(card_id, due[0].id);

    const stats = try store.stats(result.candidate.due_at_ms, deck_id);
    try std.testing.expectEqual(@as(usize, 1), stats.card_count);
    try std.testing.expectEqual(@as(usize, 1), stats.review_count);
    try std.testing.expectEqual(@as(usize, 1), stats.due_count);
}
