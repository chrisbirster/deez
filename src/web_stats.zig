const std = @import("std");
const httpz = @import("httpz");

const storage = @import("storage/root.zig");
const time = @import("time.zig");

const Io = std.Io;

const Period = enum {
    all,
    today,
    week,
    month,
    year,
};

fn periodName(period: Period) []const u8 {
    return switch (period) {
        .all => "all",
        .today => "today",
        .week => "week",
        .month => "month",
        .year => "year",
    };
}

fn parsePeriod(value: []const u8) !Period {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "today")) return .today;
    if (std.mem.eql(u8, value, "week")) return .week;
    if (std.mem.eql(u8, value, "month")) return .month;
    if (std.mem.eql(u8, value, "year")) return .year;
    return error.InvalidStatsPeriod;
}

fn startMs(period: Period, now_ms: i64) ?i64 {
    const today_start = @divFloor(now_ms, time.milliseconds_per_day) * time.milliseconds_per_day;
    return switch (period) {
        .all => null,
        .today => today_start,
        .week => today_start - 6 * time.milliseconds_per_day,
        .month => today_start - 29 * time.milliseconds_per_day,
        .year => today_start - 364 * time.milliseconds_per_day,
    };
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn parseDeckId(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidId;
}

pub fn stats(
    store: *storage.Store,
    io: Io,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const query = try req.query();
    const period = parsePeriod(query.get("period") orelse "all") catch {
        try jsonError(res, 400, "invalid_period", "period must be all, today, week, month, or year");
        return;
    };

    const deck_id: ?u64 = if (query.get("deck_id")) |value|
        parseDeckId(value) catch {
            try jsonError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
            return;
        }
    else
        null;

    if (deck_id) |id| {
        if (try store.getDeck(res.arena, id) == null) {
            try jsonError(res, 404, "deck_not_found", "Deck not found");
            return;
        }
    }

    const now_ms = Io.Timestamp.now(io, .real).toSeconds() * 1_000;
    const totals = try store.stats(now_ms, deck_id);
    const history = try storage.historicalStats(
        res.arena,
        store,
        deck_id,
        startMs(period, now_ms),
        now_ms + 1,
    );

    try res.json(.{
        .period = periodName(period),
        .totals = .{
            .decks = totals.deck_count,
            .cards = totals.card_count,
            .due = totals.due_count,
            .reviews = totals.review_count,
        },
        .history = .{
            .reviews = history.review_count,
            .unique_cards = history.unique_cards,
            .new_cards = history.new_cards,
            .again = history.again,
            .hard = history.hard,
            .good = history.good,
            .easy = history.easy,
            .days_studied = history.days_studied,
            .current_streak_days = history.current_streak_days,
            .longest_streak_days = history.longest_streak_days,
            .observed_retention = history.observedRetention(),
        },
    }, .{});
}

test "web stats periods match CLI windows" {
    const day = time.milliseconds_per_day;
    const now_ms = 100 * day + 1234;
    try std.testing.expect(startMs(.all, now_ms) == null);
    try std.testing.expectEqual(@as(i64, 100 * day), startMs(.today, now_ms).?);
    try std.testing.expectEqual(@as(i64, 94 * day), startMs(.week, now_ms).?);
    try std.testing.expectEqual(@as(i64, 71 * day), startMs(.month, now_ms).?);
    try std.testing.expectEqual(@as(i64, -264 * day), startMs(.year, now_ms).?);
}

test "web stats parses supported periods" {
    try std.testing.expectEqual(Period.all, try parsePeriod("all"));
    try std.testing.expectEqual(Period.today, try parsePeriod("today"));
    try std.testing.expectEqual(Period.week, try parsePeriod("week"));
    try std.testing.expectEqual(Period.month, try parsePeriod("month"));
    try std.testing.expectEqual(Period.year, try parsePeriod("year"));
    try std.testing.expectError(error.InvalidStatsPeriod, parsePeriod("quarter"));
}
