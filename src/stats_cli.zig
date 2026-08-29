const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config = @import("config.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const help_text =
    \\Historical stats:
    \\  deez stats [deck-id] [--period all|today|week|month|year] [--json]
    \\
    \\Periods use UTC day boundaries. Current deck/card/due totals are retained
    \\while review-history metrics are calculated from immutable reviews.
;

const Request = struct {
    deck_id: ?u64 = null,
    window: cli.StatsWindow = .all,
    json: bool = false,
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "stats");
}

fn parseWindow(text: []const u8) !cli.StatsWindow {
    if (std.mem.eql(u8, text, "all")) return .all;
    if (std.mem.eql(u8, text, "today")) return .today;
    if (std.mem.eql(u8, text, "week")) return .week;
    if (std.mem.eql(u8, text, "month")) return .month;
    if (std.mem.eql(u8, text, "year")) return .year;
    return error.InvalidStatsWindow;
}

fn parse(args: []const []const u8) !Request {
    if (!isCommand(args)) return error.InvalidArguments;
    var result: Request = .{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (result.json) return error.InvalidArguments;
            result.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--period")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            result.window = try parseWindow(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--period=")) {
            result.window = try parseWindow(arg["--period=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (result.deck_id != null) return error.InvalidArguments;
        result.deck_id = std.fmt.parseInt(u64, arg, 10) catch return error.InvalidId;
    }
    return result;
}

fn windowName(window: cli.StatsWindow) []const u8 {
    return switch (window) {
        .all => "all",
        .today => "today",
        .week => "week",
        .month => "month",
        .year => "year",
    };
}

fn startMs(window: cli.StatsWindow, now_ms: i64) ?i64 {
    const today_start = @divFloor(now_ms, time.milliseconds_per_day) * time.milliseconds_per_day;
    return switch (window) {
        .all => null,
        .today => today_start,
        .week => today_start - 6 * time.milliseconds_per_day,
        .month => today_start - 29 * time.milliseconds_per_day,
        .year => today_start - 364 * time.milliseconds_per_day,
    };
}

fn printReport(
    out: *Io.Writer,
    request: Request,
    totals: storage.Stats,
    history: storage.HistoricalStats,
) !void {
    if (request.json) {
        try out.print(
            "{{\"decks\":{d},\"cards\":{d},\"due\":{d},\"reviews\":{d},\"period\":\"{s}\",\"history_reviews\":{d},\"unique_cards\":{d},\"new_cards\":{d},\"again\":{d},\"hard\":{d},\"good\":{d},\"easy\":{d},\"days_studied\":{d},\"current_streak_days\":{d},\"longest_streak_days\":{d},\"observed_retention\":{d}}}\n",
            .{
                totals.deck_count,
                totals.card_count,
                totals.due_count,
                totals.review_count,
                windowName(request.window),
                history.review_count,
                history.unique_cards,
                history.new_cards,
                history.again,
                history.hard,
                history.good,
                history.easy,
                history.days_studied,
                history.current_streak_days,
                history.longest_streak_days,
                history.observedRetention(),
            },
        );
        return;
    }

    try out.print("Decks: {d}\nCards: {d}\nDue: {d}\nReviews: {d}\n", .{
        totals.deck_count,
        totals.card_count,
        totals.due_count,
        totals.review_count,
    });
    try out.print(
        "\nReview history ({s})\nReviews: {d}\nUnique cards: {d}\nNew cards introduced: {d}\nAgain: {d}\nHard: {d}\nGood: {d}\nEasy: {d}\nRecall rate: {d:.2}%\nDays studied: {d}\nCurrent streak: {d} days\nLongest streak: {d} days\n",
        .{
            windowName(request.window),
            history.review_count,
            history.unique_cards,
            history.new_cards,
            history.again,
            history.hard,
            history.good,
            history.easy,
            history.observedRetention() * 100.0,
            history.days_studied,
            history.current_streak_days,
            history.longest_streak_days,
        },
    );
}

fn runWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    store: *storage.Store,
    request: Request,
) !void {
    const now_ms = nowMs(io);
    const totals = try store.stats(now_ms, request.deck_id);
    const history = try storage.historicalStats(
        allocator,
        store,
        request.deck_id,
        startMs(request.window, now_ms),
        now_ms + 1,
    );
    try printReport(out, request, totals, history);
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const request = try parse(args);
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    switch (selection.backend) {
        .mongodb => {
            const mongo = try storage.MongoStore.connect(init.io, allocator, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            try runWithStore(allocator, init.io, out, &store, request);
        },
        .sqlite => {
            const db_path_z = try arena.dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            try runWithStore(allocator, init.io, out, &store, request);
        },
    }
}

test "stats parser accepts period deck and json in either order" {
    const a = [_][]const u8{ "deez", "stats", "4", "--period", "year", "--json" };
    const parsed_a = try parse(&a);
    try std.testing.expectEqual(@as(?u64, 4), parsed_a.deck_id);
    try std.testing.expectEqual(cli.StatsWindow.year, parsed_a.window);
    try std.testing.expect(parsed_a.json);

    const b = [_][]const u8{ "deez", "stats", "--json", "--period=month" };
    const parsed_b = try parse(&b);
    try std.testing.expectEqual(@as(?u64, null), parsed_b.deck_id);
    try std.testing.expectEqual(cli.StatsWindow.month, parsed_b.window);
    try std.testing.expect(parsed_b.json);
}
