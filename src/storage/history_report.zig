const std = @import("std");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");

pub const HistoricalStats = struct {
    review_count: usize = 0,
    unique_cards: usize = 0,
    new_cards: usize = 0,
    again: usize = 0,
    hard: usize = 0,
    good: usize = 0,
    easy: usize = 0,
    days_studied: usize = 0,
    current_streak_days: usize = 0,
    longest_streak_days: usize = 0,

    pub fn recalled(self: HistoricalStats) usize {
        return self.hard + self.good + self.easy;
    }

    pub fn observedRetention(self: HistoricalStats) f64 {
        if (self.review_count == 0) return 0;
        return @as(f64, @floatFromInt(self.recalled())) / @as(f64, @floatFromInt(self.review_count));
    }
};

fn inWindow(entry: fsrs.HistoryEntry, start_ms: ?time.TimestampMs, end_ms_exclusive: time.TimestampMs) bool {
    if (entry.reviewed_at_ms >= end_ms_exclusive) return false;
    if (start_ms) |start| return entry.reviewed_at_ms >= start;
    return true;
}

fn containsDay(days: []const i64, day: i64) bool {
    for (days) |candidate| if (candidate == day) return true;
    return false;
}

fn sortDays(days: []i64) void {
    var i: usize = 1;
    while (i < days.len) : (i += 1) {
        const value = days[i];
        var j = i;
        while (j > 0 and days[j - 1] > value) : (j -= 1) days[j] = days[j - 1];
        days[j] = value;
    }
}

fn streaks(days: []const i64, today: i64) struct { current: usize, longest: usize } {
    if (days.len == 0) return .{ .current = 0, .longest = 0 };

    var longest: usize = 1;
    var run: usize = 1;
    var index: usize = 1;
    while (index < days.len) : (index += 1) {
        if (days[index] == days[index - 1] + 1) {
            run += 1;
            longest = @max(longest, run);
        } else {
            run = 1;
        }
    }

    var current: usize = 0;
    const last = days[days.len - 1];
    if (last == today or last == today - 1) {
        current = 1;
        var cursor = days.len - 1;
        while (cursor > 0 and days[cursor - 1] == days[cursor] - 1) {
            current += 1;
            cursor -= 1;
        }
    }
    return .{ .current = current, .longest = longest };
}

/// Calculate historical metrics from immutable card histories. This deliberately
/// consumes the storage-neutral history contract so SQLite and MongoDB report
/// identical semantics.
pub fn calculate(
    allocator: std.mem.Allocator,
    histories: []const []const fsrs.HistoryEntry,
    start_ms: ?time.TimestampMs,
    end_ms_exclusive: time.TimestampMs,
) !HistoricalStats {
    if (start_ms) |start| if (start >= end_ms_exclusive) return error.InvalidStatsWindow;

    var result: HistoricalStats = .{};
    var days: std.ArrayList(i64) = .empty;
    defer days.deinit(allocator);

    for (histories) |history| {
        if (history.len == 0) continue;
        var touched = false;
        if (inWindow(history[0], start_ms, end_ms_exclusive)) result.new_cards += 1;

        for (history) |entry| {
            if (!inWindow(entry, start_ms, end_ms_exclusive)) continue;
            touched = true;
            result.review_count += 1;
            switch (entry.rating) {
                .again => result.again += 1,
                .hard => result.hard += 1,
                .good => result.good += 1,
                .easy => result.easy += 1,
            }
            const day = @divFloor(entry.reviewed_at_ms, time.milliseconds_per_day);
            if (!containsDay(days.items, day)) try days.append(allocator, day);
        }
        if (touched) result.unique_cards += 1;
    }

    sortDays(days.items);
    result.days_studied = days.items.len;
    const today = @divFloor(end_ms_exclusive - 1, time.milliseconds_per_day);
    const calculated = streaks(days.items, today);
    result.current_streak_days = calculated.current;
    result.longest_streak_days = calculated.longest;
    return result;
}

test "historical stats preserve ratings new cards and streaks" {
    const day = time.milliseconds_per_day;
    const a = [_]fsrs.HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = day },
        .{ .rating = .easy, .reviewed_at_ms = day * 2 },
    };
    const b = [_]fsrs.HistoryEntry{
        .{ .rating = .again, .reviewed_at_ms = day * 2 },
    };
    const histories = [_][]const fsrs.HistoryEntry{ &a, &b };
    const result = try calculate(std.testing.allocator, &histories, null, day * 3);
    try std.testing.expectEqual(@as(usize, 3), result.review_count);
    try std.testing.expectEqual(@as(usize, 2), result.unique_cards);
    try std.testing.expectEqual(@as(usize, 2), result.new_cards);
    try std.testing.expectEqual(@as(usize, 1), result.again);
    try std.testing.expectEqual(@as(usize, 1), result.good);
    try std.testing.expectEqual(@as(usize, 1), result.easy);
    try std.testing.expectEqual(@as(usize, 2), result.days_studied);
    try std.testing.expectEqual(@as(usize, 2), result.longest_streak_days);
}

test "window counts a card as new only when its first review is inside the window" {
    const day = time.milliseconds_per_day;
    const a = [_]fsrs.HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = day },
        .{ .rating = .hard, .reviewed_at_ms = day * 5 },
    };
    const b = [_]fsrs.HistoryEntry{
        .{ .rating = .easy, .reviewed_at_ms = day * 5 },
    };
    const histories = [_][]const fsrs.HistoryEntry{ &a, &b };
    const result = try calculate(std.testing.allocator, &histories, day * 4, day * 6);
    try std.testing.expectEqual(@as(usize, 2), result.review_count);
    try std.testing.expectEqual(@as(usize, 2), result.unique_cards);
    try std.testing.expectEqual(@as(usize, 1), result.new_cards);
}
