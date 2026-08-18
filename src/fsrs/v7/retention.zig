const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;
const simulator = @import("simulator.zig");

pub const Config = struct {
    minimum_retention: f64 = 0.80,
    maximum_retention: f64 = 0.99,
    step: f64 = 0.01,
    lapse_penalty_seconds: f64 = 30.0,
    simulation: simulator.Config = .{},
};

pub const Point = struct {
    desired_retention: f64,
    reviews: usize,
    lapses: usize,
    average_daily_reviews: f64,
    estimated_study_seconds: f64,
    average_retrievability_at_horizon: f64,
    total_cost_seconds: f64,
};

pub const Analysis = struct {
    points: []Point,
    optimal_retention: f64,
    minimum_cost_seconds: f64,

    pub fn deinit(self: Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    base_parameters: Parameters,
    config: Config,
) !Analysis {
    if (!std.math.isFinite(config.minimum_retention) or !std.math.isFinite(config.maximum_retention) or
        config.minimum_retention <= 0 or config.maximum_retention >= 1 or
        config.minimum_retention > config.maximum_retention)
    {
        return error.InvalidRetentionRange;
    }
    if (!std.math.isFinite(config.step) or config.step <= 0) return error.InvalidRetentionStep;
    if (!std.math.isFinite(config.lapse_penalty_seconds) or config.lapse_penalty_seconds < 0) return error.InvalidLapsePenalty;

    var points: std.ArrayList(Point) = .empty;
    errdefer points.deinit(allocator);

    var retention = config.minimum_retention;
    var best_retention = retention;
    var best_cost = std.math.inf(f64);
    while (retention <= config.maximum_retention + 1e-12) : (retention += config.step) {
        var parameters = base_parameters;
        parameters.desired_retention = @min(retention, config.maximum_retention);
        try parameters.validate();

        const simulation = try simulator.simulate(allocator, parameters, config.simulation);
        const total_cost = simulation.estimated_study_seconds +
            @as(f64, @floatFromInt(simulation.lapses)) * config.lapse_penalty_seconds;

        try points.append(allocator, .{
            .desired_retention = parameters.desired_retention,
            .reviews = simulation.reviews,
            .lapses = simulation.lapses,
            .average_daily_reviews = simulation.average_daily_reviews,
            .estimated_study_seconds = simulation.estimated_study_seconds,
            .average_retrievability_at_horizon = simulation.average_retrievability_at_horizon,
            .total_cost_seconds = total_cost,
        });

        if (total_cost < best_cost) {
            best_cost = total_cost;
            best_retention = parameters.desired_retention;
        }
    }

    return .{
        .points = try points.toOwnedSlice(allocator),
        .optimal_retention = best_retention,
        .minimum_cost_seconds = best_cost,
    };
}

test "retention analysis returns workload curve and optimum" {
    const analysis = try analyze(std.testing.allocator, .{}, .{
        .minimum_retention = 0.85,
        .maximum_retention = 0.95,
        .step = 0.05,
        .simulation = .{ .card_count = 10, .horizon_days = 30, .new_cards_per_day = 5, .seed = 42 },
    });
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), analysis.points.len);
    try std.testing.expect(analysis.optimal_retention >= 0.85 and analysis.optimal_retention <= 0.95);
    try std.testing.expect(std.math.isFinite(analysis.minimum_cost_seconds));
}
