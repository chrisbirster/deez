const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";
const standalone_uri = "mongodb://admin:secretpassword@localhost:27017/deez_standalone?authSource=admin";

fn connectStore(uri: []const u8) !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    );
    return .{ .mongodb = mongo };
}

fn expectConnectFailure(uri: []const u8) !void {
    if (deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    )) |mongo| {
        var unexpected = mongo;
        unexpected.deinit();
        return error.ExpectedMongoConnectFailure;
    } else |_| {}
}

fn containsCard(cards: []const deez.storage.OwnedDueCard, card_id: u64) bool {
    for (cards) |card| {
        if (card.id == card_id) return true;
    }
    return false;
}

test "MongoStore supports Deez transaction workflow and reconnect" {
    const allocator = std.testing.allocator;

    var deck_id: u64 = undefined;
    var card_id: u64 = undefined;
    var second_card_id: u64 = undefined;
    var due_at_ms: i64 = undefined;
    var expected_stability: f64 = undefined;

    {
        var store = try connectStore(replica_uri);
        defer store.deinit();

        try std.testing.expect(store.mongodb.client.supports_sessions);
        try std.testing.expect(store.mongodb.client.supports_transactions);

        deck_id = try store.createDeck("mongo-integration", 0);
        _ = try store.ensureDefaultFsrs7(0);
        card_id = try store.createCard(
            deck_id,
            "What is BSON?",
            "Binary JSON",
            0,
        );
        second_card_id = try store.createCard(
            deck_id,
            "What is Zig?",
            "A systems programming language",
            1,
        );

        const loaded_deck = (try store.getDeck(allocator, deck_id)) orelse
            return error.MissingDeck;
        defer loaded_deck.deinit(allocator);
        try std.testing.expectEqualStrings("mongo-integration", loaded_deck.name);

        const loaded_card = (try store.getCard(allocator, card_id)) orelse
            return error.MissingCard;
        defer loaded_card.deinit(allocator);
        try std.testing.expectEqual(deck_id, loaded_card.deck_id);
        try std.testing.expectEqualStrings("What is BSON?", loaded_card.question);

        const initially_due = try store.dueCards(allocator, deck_id, 1, 10);
        defer {
            for (initially_due) |card| card.deinit(allocator);
            allocator.free(initially_due);
        }
        try std.testing.expectEqual(@as(usize, 2), initially_due.len);
        try std.testing.expect(containsCard(initially_due, card_id));
        try std.testing.expect(containsCard(initially_due, second_card_id));

        const study = deez.Study.init(&store);
        const result = try study.recordReview(
            allocator,
            card_id,
            .good,
            deez.time.milliseconds_per_day,
        );
        due_at_ms = result.state.due_at_ms;
        expected_stability = result.state.stability_days.?;

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

        const due = try store.dueCards(allocator, deck_id, due_at_ms, 10);
        defer {
            for (due) |card| card.deinit(allocator);
            allocator.free(due);
        }
        try std.testing.expect(containsCard(due, card_id));

        const stats = try store.stats(due_at_ms, deck_id);
        try std.testing.expectEqual(@as(usize, 2), stats.card_count);
        try std.testing.expectEqual(@as(usize, 1), stats.review_count);
        try std.testing.expectEqual(@as(usize, 2), stats.due_count);
    }

    // A new RuntimeClient must see the same Deez records. This proves the
    // backend is using MongoDB persistence rather than process-local state.
    {
        var store = try connectStore(replica_uri);
        defer store.deinit();
        defer store.deleteDeck(deck_id) catch {};

        const loaded_deck = (try store.getDeck(allocator, deck_id)) orelse
            return error.MissingDeckAfterReconnect;
        defer loaded_deck.deinit(allocator);
        try std.testing.expectEqualStrings("mongo-integration", loaded_deck.name);

        const loaded_card = (try store.getCard(allocator, card_id)) orelse
            return error.MissingCardAfterReconnect;
        defer loaded_card.deinit(allocator);
        try std.testing.expectEqualStrings("Binary JSON", loaded_card.answer);

        const history = try store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        try std.testing.expectEqual(@as(usize, 1), history.len);
        try std.testing.expectEqual(deez.fsrs.Rating.good, history[0].rating);

        const state = (try store.getSchedulerState(card_id)) orelse
            return error.MissingStateAfterReconnect;
        try std.testing.expectEqual(due_at_ms, state.due_at_ms);
        try std.testing.expectApproxEqAbs(
            expected_stability,
            state.stability_days.?,
            1e-12,
        );
    }
}

test "MongoStore standalone fallback preserves review history and derived state" {
    const allocator = std.testing.allocator;
    var store = try connectStore(standalone_uri);
    defer store.deinit();

    try std.testing.expect(!store.mongodb.client.supports_transactions);

    const deck_id = try store.createDeck("mongo-standalone", 0);
    defer store.deleteDeck(deck_id) catch {};
    _ = try store.ensureDefaultFsrs7(0);
    const card_id = try store.createCard(deck_id, "Fallback?", "Review first", 0);

    const study = deez.Study.init(&store);
    const result = try study.recordReview(
        allocator,
        card_id,
        .hard,
        deez.time.milliseconds_per_day,
    );

    const history = try store.loadHistory(allocator, card_id);
    defer allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(deez.fsrs.Rating.hard, history[0].rating);

    const stored = (try store.getSchedulerState(card_id)) orelse
        return error.MissingStandaloneSchedulerState;
    try std.testing.expectEqual(result.state.due_at_ms, stored.due_at_ms);

    // Derived state is disposable. The immutable review remains and is enough
    // for Deez to reconstruct the same FSRS memory state.
    try store.clearSchedulerState(card_id);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);
    const rebuilt = (try study.rebuildCardState(
        allocator,
        card_id,
        deez.time.milliseconds_per_day,
    )) orelse return error.MissingRebuiltStandaloneState;
    try std.testing.expectApproxEqAbs(
        result.state.stability_days.?,
        rebuilt.stability_days.?,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        result.state.difficulty.?,
        rebuilt.difficulty.?,
        1e-12,
    );
}

test "MongoStore propagates startup authentication and TLS failures" {
    try expectConnectFailure("mongodb://localhost:27099/deez_unreachable");
    try expectConnectFailure(
        "mongodb://admin:wrong-password@localhost:27017/deez_auth_failure?authSource=admin",
    );
    try expectConnectFailure(
        "mongodb://admin:secretpassword@localhost:27018/deez_tls_failure?authSource=admin&tls=true",
    );
}
