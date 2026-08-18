const std = @import("std");
const AlgorithmId = @import("algorithm.zig").AlgorithmId;
const HistoryEntry = @import("history.zig").Entry;
const Schedule = @import("schedule.zig").Schedule;
const TimestampMs = @import("../time.zig").TimestampMs;
const v7 = @import("v7/root.zig");

pub const Engine = union(enum) {
    fsrs7: v7.Engine,

    pub fn defaultFsrs7() Engine {
        return .{ .fsrs7 = .{} };
    }

    pub fn fsrs7With(parameters: v7.Parameters) !Engine {
        return .{ .fsrs7 = try v7.Engine.init(parameters) };
    }

    pub fn forAlgorithm(algorithm_id: AlgorithmId) !Engine {
        if (algorithm_id.eql(.fsrs7)) return defaultFsrs7();
        return error.UnsupportedAlgorithm;
    }

    pub fn algorithm(self: Engine) AlgorithmId {
        return switch (self) {
            .fsrs7 => .fsrs7,
        };
    }

    pub fn schedule(self: Engine, history: []const HistoryEntry, now_ms: TimestampMs) !Schedule {
        return switch (self) {
            .fsrs7 => |engine| engine.schedule(history, now_ms),
        };
    }
};

test "engine dispatch is versioned" {
    const engine = try Engine.forAlgorithm(.fsrs7);
    try std.testing.expect(engine.algorithm().eql(.fsrs7));
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        Engine.forAlgorithm(.{ .family = .fsrs, .major = 8 }),
    );
}

test "engine accepts versioned custom parameters" {
    var parameters: v7.Parameters = .{};
    parameters.desired_retention = 0.95;
    const engine = try Engine.fsrs7With(parameters);
    const schedule = try engine.schedule(&.{}, 0);
    const default_schedule = try Engine.defaultFsrs7().schedule(&.{}, 0);
    try std.testing.expect(schedule.good.interval_days < default_schedule.good.interval_days);
}

test "engine returns version-independent schedule results" {
    const engine = Engine.defaultFsrs7();
    const schedule = try engine.schedule(&.{}, 0);
    try std.testing.expect(schedule.good.interval_days > 0);
}
