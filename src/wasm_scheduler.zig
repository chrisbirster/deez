const std = @import("std");
const fsrs = @import("fsrs/root.zig");

const max_history = 8192;

var parameters: fsrs.v7.Parameters = .{};
var history_buffer: [max_history]fsrs.HistoryEntry = undefined;
var history_len: usize = 0;
var last_schedule: ?fsrs.Schedule = null;
var last_stability_days: f64 = std.math.nan(f64);
var last_difficulty: f64 = std.math.nan(f64);
var last_error: i32 = 0;

fn fail(code: i32) i32 {
    last_error = code;
    return code;
}

fn rating(raw: u32) ?fsrs.Rating {
    return fsrs.Rating.fromValue(@intCast(raw)) catch null;
}

fn candidate(raw: u32) ?fsrs.Candidate {
    const schedule = last_schedule orelse return null;
    return schedule.forRating(rating(raw) orelse return null);
}

fn replayMemory(engine: fsrs.v7.Engine) !void {
    const state = try engine.replay(history_buffer[0..history_len]);
    if (state) |value| {
        last_stability_days = value.memory.stability_days;
        last_difficulty = value.memory.difficulty;
    } else {
        last_stability_days = std.math.nan(f64);
        last_difficulty = std.math.nan(f64);
    }
}

pub export fn deez_reset() void {
    parameters = .{};
    history_len = 0;
    last_schedule = null;
    last_stability_days = std.math.nan(f64);
    last_difficulty = std.math.nan(f64);
    last_error = 0;
}

pub export fn deez_history_len() u32 {
    return @intCast(history_len);
}

pub export fn deez_set_weight(index: u32, value: f64) i32 {
    if (index >= parameters.weights.len or !std.math.isFinite(value)) return fail(-1);
    parameters.weights[index] = value;
    last_error = 0;
    return 0;
}

pub export fn deez_set_desired_retention(value: f64) i32 {
    parameters.desired_retention = value;
    last_error = 0;
    return 0;
}

pub export fn deez_set_minimum_interval_days(value: f64) i32 {
    parameters.minimum_interval_days = value;
    last_error = 0;
    return 0;
}

pub export fn deez_set_maximum_interval_days(value: f64) i32 {
    parameters.maximum_interval_days = value;
    last_error = 0;
    return 0;
}

pub export fn deez_validate_parameters() i32 {
    parameters.validate() catch return fail(-2);
    last_error = 0;
    return 0;
}

pub export fn deez_append_review(raw_rating: u32, reviewed_at_ms: i64) i32 {
    const parsed = rating(raw_rating) orelse return fail(-3);
    if (history_len >= max_history) return fail(-4);
    if (history_len != 0 and reviewed_at_ms <= history_buffer[history_len - 1].reviewed_at_ms) return fail(-5);
    history_buffer[history_len] = .{ .rating = parsed, .reviewed_at_ms = reviewed_at_ms };
    history_len += 1;
    last_schedule = null;
    last_error = 0;
    return 0;
}

pub export fn deez_schedule(now_ms: i64) i32 {
    parameters.validate() catch return fail(-2);
    if (history_len != 0 and now_ms < history_buffer[history_len - 1].reviewed_at_ms) return fail(-6);
    const engine = fsrs.v7.Engine.init(parameters) catch return fail(-7);
    last_schedule = engine.schedule(history_buffer[0..history_len], now_ms) catch return fail(-8);
    replayMemory(engine) catch return fail(-9);
    last_error = 0;
    return 0;
}

pub export fn deez_due_at_ms(raw_rating: u32) i64 {
    return if (candidate(raw_rating)) |value| value.due_at_ms else -1;
}

pub export fn deez_interval_days(raw_rating: u32) f64 {
    return if (candidate(raw_rating)) |value| value.interval_days else std.math.nan(f64);
}

pub export fn deez_stability_days() f64 {
    return last_stability_days;
}

pub export fn deez_difficulty() f64 {
    return last_difficulty;
}

pub export fn deez_last_error() i32 {
    return last_error;
}

test "wasm scheduler API matches direct FSRS scheduling" {
    deez_reset();
    try std.testing.expectEqual(@as(i32, 0), deez_validate_parameters());
    try std.testing.expectEqual(@as(i32, 0), deez_schedule(1_000));
    const engine = try fsrs.v7.Engine.init(.{});
    const expected = try engine.schedule(&.{}, 1_000);
    try std.testing.expectEqual(expected.good.due_at_ms, deez_due_at_ms(3));
    try std.testing.expectApproxEqAbs(expected.good.interval_days, deez_interval_days(3), 1e-12);

    try std.testing.expectEqual(@as(i32, 0), deez_append_review(3, 1_000));
    try std.testing.expectEqual(@as(u32, 1), deez_history_len());
    try std.testing.expectEqual(@as(i32, 0), deez_schedule(expected.good.due_at_ms));
    const one = [_]fsrs.HistoryEntry{.{ .rating = .good, .reviewed_at_ms = 1_000 }};
    const expected_second = try engine.schedule(&one, expected.good.due_at_ms);
    try std.testing.expectEqual(expected_second.again.due_at_ms, deez_due_at_ms(1));
    try std.testing.expect(std.math.isFinite(deez_stability_days()));
    try std.testing.expect(std.math.isFinite(deez_difficulty()));
}
