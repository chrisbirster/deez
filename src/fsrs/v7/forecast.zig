const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;
const simulator = @import("simulator.zig");

pub const Bucket = struct {
    start_day: usize,
    end_day_exclusive: usize,
    reviews: usize,
    estimated_study_seconds: f64,
};

pub const Forecast = struct {
    daily: []Bucket,
    weekly: []Bucket,
    monthly: []Bucket,

    pub fn deinit(self: Forecast, allocator: std.mem.Allocator) void {
        allocator.free(self.daily);
        allocator.free(self.weekly);
        allocator.free(self.monthly);
    }
};

fn cumulativeReviews(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    base: simulator.Config,
    horizon_days: usize,
) !usize {
    var config = base;
    config.horizon_days = horizon_days;
    return (try simulator.simulate(allocator, parameters, config)).reviews;
}

fn aggregate(
    allocator: std.mem.Allocator,
    daily: []const Bucket,
    width_days: usize,
    seconds_per_review: f64,
) ![]Bucket {
    const count = (daily.len + width_days - 1) / width_days;
    const result = try allocator.alloc(Bucket, count);
    errdefer allocator.free(result);

    for (result, 0..) |*bucket, index| {
        const start = index * width_days;
        const end = @min(start + width_days, daily.len);
        var reviews: usize = 0;
        for (daily[start..end]) |day| reviews += day.reviews;
        bucket.* = .{
            .start_day = start,
            .end_day_exclusive = end,
            .reviews = reviews,
            .estimated_study_seconds = @as(f64, @floatFromInt(reviews)) * seconds_per_review,
        };
    }
    return result;
}

/// Forecast expected workload by deriving deterministic cumulative simulations
/// over increasing horizons. This is intentionally slower than a single
/// simulation but keeps the daily/weekly/monthly result API independent from
/// the simulator's internal representation.
pub fn forecast(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    config: simulator.Config,
) !Forecast {
    try parameters.validate();
    if (config.horizon_days == 0) return error.InvalidHorizon;

    const daily = try allocator.alloc(Bucket, config.horizon_days);
    errdefer allocator.free(daily);

    var previous_total: usize = 0;
    for (daily, 0..) |*bucket, index| {
        const total = try cumulativeReviews(allocator, parameters, config, index + 1);
        if (total < previous_total) return error.NonMonotonicSimulation;
        const reviews = total - previous_total;
        bucket.* = .{
            .start_day = index,
            .end_day_exclusive = index + 1,
            .reviews = reviews,
            .estimated_study_seconds = @as(f64, @floatFromInt(reviews)) * config.seconds_per_review,
        };
        previous_total = total;
    }

    const weekly = try aggregate(allocator, daily, 7, config.seconds_per_review);
    errdefer allocator.free(weekly);
    const monthly = try aggregate(allocator, daily, 30, config.seconds_per_review);

    return .{
        .daily = daily,
        .weekly = weekly,
        .monthly = monthly,
    };
}

test "forecast returns daily weekly and monthly buckets" {
    const config: simulator.Config = .{
        .card_count = 20,
        .horizon_days = 31,
        .new_cards_per_day = 5,
        .seed = 123,
    };
    const result = try forecast(std.testing.allocator, .{}, config);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 31), result.daily.len);
    try std.testing.expectEqual(@as(usize, 5), result.weekly.len);
    try std.testing.expectEqual(@as(usize, 2), result.monthly.len);

    var daily_total: usize = 0;
    for (result.daily) |bucket| daily_total += bucket.reviews;
    var weekly_total: usize = 0;
    for (result.weekly) |bucket| weekly_total += bucket.reviews;
    var monthly_total: usize = 0;
    for (result.monthly) |bucket| monthly_total += bucket.reviews;

    try std.testing.expectEqual(daily_total, weekly_total);
    try std.testing.expectEqual(daily_total, monthly_total);
}
