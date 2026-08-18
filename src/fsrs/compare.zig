const std = @import("std");
const Engine = @import("engine.zig").Engine;
const HistoryEntry = @import("history.zig").Entry;
const Schedule = @import("schedule.zig").Schedule;
const TimestampMs = @import("../time.zig").TimestampMs;

pub const Comparison = struct {
    source_algorithm: @import("algorithm.zig").AlgorithmId,
    target_algorithm: @import("algorithm.zig").AlgorithmId,
    source: Schedule,
    target: Schedule,
};

pub fn compare(
    source_engine: Engine,
    target_engine: Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
) !Comparison {
    return .{
        .source_algorithm = source_engine.algorithm(),
        .target_algorithm = target_engine.algorithm(),
        .source = try source_engine.schedule(history, now_ms),
        .target = try target_engine.schedule(history, now_ms),
    };
}

test "comparison is side-effect free and reflects parameter differences" {
    const v7 = @import("v7/root.zig");
    var high_retention: v7.Parameters = .{};
    high_retention.desired_retention = 0.95;

    const source = Engine.defaultFsrs7();
    const target = try Engine.fsrs7With(high_retention);
    const result = try compare(source, target, &.{}, 0);

    try std.testing.expect(result.source_algorithm.eql(.fsrs7));
    try std.testing.expect(result.target_algorithm.eql(.fsrs7));
    try std.testing.expect(result.target.good.interval_days < result.source.good.interval_days);
}
