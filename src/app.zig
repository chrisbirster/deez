const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");

fn nowMs(io: Io) i64 {
    const seconds = Io.Timestamp.now(io, .real).toSeconds();
    return seconds * 1_000;
}

fn printInterval(out: *Io.Writer, days: f64) !void {
    if (days < 1.0 / 24.0) {
        try out.print("{d:.1}m", .{days * 24.0 * 60.0});
    } else if (days < 1.0) {
        try out.print("{d:.1}h", .{days * 24.0});
    } else {
        try out.print("{d:.1}d", .{days});
    }
}

fn readByte(io: Io) !u8 {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{buffer[0..]};
    while (true) {
        const read = try Io.File.stdin().readStreaming(io, &buffers);
        if (read == 0) return error.EndOfStream;
        return buffer[0];
    }
}

fn waitForEnter(io: Io) !void {
    while (try readByte(io) != '\n') {}
}

fn readRating(io: Io) !fsrs.Rating {
    while (true) {
        const byte = try readByte(io);
        if (byte >= '1' and byte <= '4') {
            while (try readByte(io) != '\n') {}
            return fsrs.Rating.fromValue(byte - '0');
        }
    }
}

fn historyViews(
    allocator: std.mem.Allocator,
    owned: storage.OwnedHistories,
) ![]const []const fsrs.HistoryEntry {
    const views = try allocator.alloc([]const fsrs.HistoryEntry, owned.histories.len);
    for (owned.histories, 0..) |history, index| views[index] = history;
    return views;
}

fn baseParameters(
    catalog: storage.Catalog,
    deck_id: ?u64,
    now_ms: i64,
) !fsrs.v7.Parameters {
    if (deck_id) |id| {
        const resolved = try catalog.resolveDeckScheduler(id, now_ms);
        if (!resolved.algorithm.eql(.fsrs7)) return error.UnsupportedAlgorithm;
        return catalog.loadFsrs7Parameters(resolved.parameter_set_id);
    }
    return .{};
}

fn studyDeck(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    study: study_mod.Study,
    deck_id: u64,
) !void {
    while (true) {
        const due = try study.dueCards(allocator, deck_id, nowMs(io), 1);
        defer {
            for (due) |card| card.deinit(allocator);
            allocator.free(due);
        }
        if (due.len == 0) {
            try out.print("No cards due.\n", .{});
            return;
        }

        const card = due[0];
        try out.print("\n{s}\n\n[press enter to reveal]", .{card.question});
        try out.flush();
        try waitForEnter(io);

        const preview = try study.preview(allocator, card.id, nowMs(io));
        try out.print("\n{s}\n\n", .{card.answer});
        try out.print("1 Again  ", .{});
        try printInterval(out, preview.schedule.again.interval_days);
        try out.print("\n2 Hard   ", .{});
        try printInterval(out, preview.schedule.hard.interval_days);
        try out.print("\n3 Good   ", .{});
        try printInterval(out, preview.schedule.good.interval_days);
        try out.print("\n4 Easy   ", .{});
        try printInterval(out, preview.schedule.easy.interval_days);
        try out.print("\n\n> ", .{});
        try out.flush();

        const rating = try readRating(io);
        const reviewed_at_ms = nowMs(io);
        const result = try study.recordReview(allocator, card.id, rating, reviewed_at_ms);
        try out.print("scheduled in ", .{});
        try printInterval(out, result.candidate.interval_days);
        try out.print("\n", .{});
        try out.flush();
    }
}

pub fn run(init: std.process.Init, command: cli.Command) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const db_path = init.environ_map.get("DEEZ_DB") orelse "deez.db";
    const db_path_z = try arena.dupeZ(u8, db_path);

    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();

    const catalog: storage.Catalog = .{ .db = &db };
    const report: storage.Report = .{ .db = &db };
    const study = study_mod.Study.init(&db);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const now_ms = nowMs(io);
    switch (command) {
        .help => try out.print("{s}", .{cli.help_text}),
        .decks => {
            const decks = try report.decks(allocator, now_ms);
            defer {
                for (decks) |deck| deck.deinit(allocator);
                allocator.free(decks);
            }
            try out.print("ID  NAME  CARDS  DUE\n", .{});
            for (decks) |deck| {
                try out.print("{d}  {s}  {d}  {d}\n", .{ deck.id, deck.name, deck.card_count, deck.due_count });
            }
        },
        .deck_add => |args| {
            const id = try db.createDeck(args.name, now_ms);
            _ = try catalog.ensureDefaultFsrs7(now_ms);
            try out.print("Created deck {d}: {s}\n", .{ id, args.name });
        },
        .deck_rename => |args| {
            try db.renameDeck(args.deck_id, args.name);
            try out.print("Renamed deck {d}.\n", .{args.deck_id});
        },
        .deck_delete => |args| {
            try db.deleteDeck(args.deck_id);
            try out.print("Deleted deck {d}.\n", .{args.deck_id});
        },
        .card_add => |args| {
            const id = try db.createCard(args.deck_id, args.question, args.answer, now_ms);
            try out.print("Created card {d}.\n", .{id});
        },
        .card_edit => |args| {
            try db.updateCard(args.card_id, args.question, args.answer);
            try out.print("Updated card {d}.\n", .{args.card_id});
        },
        .card_delete => |args| {
            try db.deleteCard(args.card_id);
            try out.print("Deleted card {d}.\n", .{args.card_id});
        },
        .study => |args| try studyDeck(allocator, io, out, study, args.deck_id),
        .stats => |args| {
            const stats = try report.stats(now_ms, args.deck_id);
            try out.print("Decks: {d}\nCards: {d}\nDue: {d}\nReviews: {d}\n", .{
                stats.deck_count,
                stats.card_count,
                stats.due_count,
                stats.review_count,
            });
        },
        .inspect => |args| {
            const preview = try study.preview(allocator, args.card_id, now_ms);
            try out.print("Card: {d}\nScheduler: FSRS-{d}\nParameter set: {x}\n", .{
                args.card_id,
                preview.algorithm.major,
                preview.parameter_set_id,
            });
            if (preview.retrievability) |value| try out.print("Retrievability: {d:.2}%\n", .{value * 100.0});
            if (try catalog.getSchedulerState(args.card_id)) |state| {
                if (state.stability_days) |value| try out.print("Stability: {d:.3} days\n", .{value});
                if (state.difficulty) |value| try out.print("Difficulty: {d:.3}\n", .{value});
                try out.print("Due: {d}\n", .{state.due_at_ms});
            }
        },
        .fsrs_optimize => |args| {
            const owned = try report.histories(allocator, args.deck_id);
            defer owned.deinit(allocator);
            const views = try historyViews(allocator, owned);
            defer allocator.free(views);
            const initial = try baseParameters(catalog, args.deck_id, now_ms);
            const result = try fsrs.v7.optimizer.optimize(views, initial, .{
                .recency_half_life_days = args.recency_half_life_days,
            });
            const id = try catalog.putFsrs7Parameters(result.parameters, "optimized", now_ms);
            if (args.deck_id) |deck_id| {
                try catalog.setDeckFsrs7(deck_id, id);
            } else {
                try catalog.setGlobalFsrs7(id);
            }
            try out.print("Examples: {d}\nLog loss: {d:.6} -> {d:.6}\nParameter set: {x}\n", .{
                result.examples,
                result.initial_log_loss,
                result.final_log_loss,
                id,
            });
        },
        .fsrs_evaluate => |args| {
            const owned = try report.histories(allocator, args.deck_id);
            defer owned.deinit(allocator);
            const views = try historyViews(allocator, owned);
            defer allocator.free(views);
            const parameters = try baseParameters(catalog, args.deck_id, now_ms);
            const metrics = try fsrs.v7.evaluator.evaluate(views, parameters, .{});
            try out.print("Examples: {d}\nLog loss: {d:.6}\nRMSE: {d:.6}\nCalibration error: {d:.6}\n", .{
                metrics.examples,
                metrics.log_loss,
                metrics.rmse,
                metrics.calibration_error,
            });
        },
        .fsrs_simulate => |args| {
            var parameters: fsrs.v7.Parameters = .{};
            if (args.retention) |retention| parameters.desired_retention = retention;
            const result = try fsrs.v7.simulator.simulate(allocator, parameters, .{});
            try out.print("Reviews: {d}\nLapses: {d}\nAverage/day: {d:.2}\nStudy time: {d:.1} minutes\nHorizon retrievability: {d:.2}%\n", .{
                result.reviews,
                result.lapses,
                result.average_daily_reviews,
                result.estimated_study_seconds / 60.0,
                result.average_retrievability_at_horizon * 100.0,
            });
        },
        .fsrs_retention => {
            const analysis = try fsrs.v7.retention.analyze(allocator, .{}, .{});
            defer analysis.deinit(allocator);
            try out.print("Suggested retention: {d:.2}%\n", .{analysis.optimal_retention * 100.0});
            for (analysis.points) |point| {
                try out.print("{d:.0}%  reviews={d}  lapses={d}  cost={d:.1}m\n", .{
                    point.desired_retention * 100.0,
                    point.reviews,
                    point.lapses,
                    point.total_cost_seconds / 60.0,
                });
            }
        },
        .scheduler_list => try out.print("FSRS-7  supported  current\n", .{}),
    }
}
