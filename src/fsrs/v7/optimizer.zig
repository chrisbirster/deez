const std = @import("std");
const HistoryEntry = @import("../history.zig").Entry;
const evaluator = @import("evaluator.zig");
const parameters_mod = @import("parameters.zig");
const Parameters = parameters_mod.Parameters;

pub const Config = struct {
    epochs: usize = 8,
    learning_rate: f64 = 0.02,
    beta1: f64 = 0.8,
    beta2: f64 = 0.85,
    epsilon: f64 = 1e-8,
    finite_difference_step: f64 = 1e-4,
    gradient_clip: f64 = 10.0,
    l2_weight: f64 = 0.5,
    minimum_examples: usize = 20,
    recency_half_life_days: ?f64 = null,
};

pub const Result = struct {
    parameters: Parameters,
    initial_log_loss: f64,
    final_log_loss: f64,
    objective_before: f64,
    objective_after: f64,
    examples: usize,
    epochs: usize,
};

const l2_sigma: [parameters_mod.weight_count]f64 = .{
    9999.0, 9999.0, 9999.0, 9999.0,
    0.523,  0.2528, 0.4329,
    0.2966, 0.2139, 0.2889, 0.1862, 0.0829, 0.175, 0.3812, 0.3013, 0.9104,
    0.3234, 0.2448, 0.3273, 0.1842, 0.1542, 0.1735, 0.4608, 0.311, 0.864,
    0.4053, 0.162,
    0.0418, 0.2596, 0.0798, 0.0682, 0.1282, 0.1397, 0.1407, 0.1489,
};

const ranges: [parameters_mod.weight_count][2]f64 = .{
    .{ 0.0001, 50.0 }, .{ 0.0001, 100.0 }, .{ 0.0001, 100.0 }, .{ 0.0001, 100.0 },
    .{ 1.0, 10.0 },    .{ 0.001, 4.0 },    .{ 0.1, 4.0 },      .{ 0.0, 4.0 },
    .{ 0.0, 1.2 },     .{ 0.3, 3.0 },      .{ 0.01, 1.5 },     .{ 0.001, 0.9 },
    .{ 0.1, 1.0 },     .{ 0.0, 3.5 },      .{ 0.0, 1.0 },      .{ 1.0, 7.0 },
    .{ 0.0, 4.0 },     .{ 0.0, 2.0 },      .{ 0.5, 6.0 },      .{ 0.001, 1.5 },
    .{ 0.001, 2.0 },   .{ 0.001, 1.0 },    .{ 0.0, 5.0 },      .{ 0.0, 1.0 },
    .{ 1.0, 7.0 },     .{ 2.5, 15.0 },     .{ 0.0, 1.0 },      .{ 0.01, 0.25 },
    .{ 0.01, 0.95 },   .{ 0.5, 0.85 },     .{ 0.5, 0.99 },     .{ 0.01, 1.0 },
    .{ 0.1, 1.0 },     .{ 0.0, 0.9 },      .{ 0.1, 1.1 },
};

fn clamp(value: f64, low: f64, high: f64) f64 {
    return @max(low, @min(value, high));
}

fn sanitize(parameters: *Parameters) void {
    for (&parameters.weights, ranges) |*weight, range| {
        weight.* = clamp(weight.*, range[0], range[1]);
    }

    parameters.weights[1] = @max(parameters.weights[1], parameters.weights[0]);
    parameters.weights[2] = @max(parameters.weights[2], parameters.weights[1]);
    parameters.weights[3] = @max(parameters.weights[3], parameters.weights[2]);
    parameters.weights[28] = @max(parameters.weights[28], parameters.weights[27]);
    parameters.weights[30] = @max(parameters.weights[30], parameters.weights[29]);
}

fn regularization(parameters: Parameters) f64 {
    var penalty: f64 = 0;
    for (parameters.weights, parameters_mod.default_weights, l2_sigma) |weight, default, sigma| {
        const normalized = (weight - default) / sigma;
        penalty += normalized * normalized;
    }
    return penalty;
}

fn objective(
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    config: Config,
) !f64 {
    const metrics = try evaluator.evaluate(histories, parameters, .{
        .recency_half_life_days = config.recency_half_life_days,
    });
    if (metrics.examples < config.minimum_examples) return error.NotEnoughReviewHistory;
    return metrics.log_loss + config.l2_weight * regularization(parameters) / @as(f64, @floatFromInt(@max(metrics.examples, 1)));
}

pub fn optimize(
    histories: []const []const HistoryEntry,
    initial_parameters: Parameters,
    config: Config,
) !Result {
    if (config.epochs == 0) return error.InvalidEpochCount;
    if (config.learning_rate <= 0 or !std.math.isFinite(config.learning_rate)) return error.InvalidLearningRate;
    if (config.finite_difference_step <= 0 or !std.math.isFinite(config.finite_difference_step)) return error.InvalidFiniteDifferenceStep;

    var parameters = initial_parameters;
    sanitize(&parameters);
    try parameters.validate();

    const evaluation_options: evaluator.Options = .{ .recency_half_life_days = config.recency_half_life_days };
    const initial_metrics = try evaluator.evaluate(histories, parameters, evaluation_options);
    if (initial_metrics.examples < config.minimum_examples) return error.NotEnoughReviewHistory;
    const before = try objective(histories, parameters, config);

    var first_moment = [_]f64{0} ** parameters_mod.weight_count;
    var second_moment = [_]f64{0} ** parameters_mod.weight_count;

    for (0..config.epochs) |epoch_index| {
        var gradient = [_]f64{0} ** parameters_mod.weight_count;

        for (0..parameters_mod.weight_count) |index| {
            const base = parameters.weights[index];
            const step = config.finite_difference_step * @max(@abs(base), 1.0);

            var plus = parameters;
            plus.weights[index] = base + step;
            sanitize(&plus);

            var minus = parameters;
            minus.weights[index] = base - step;
            sanitize(&minus);

            const denominator = plus.weights[index] - minus.weights[index];
            if (@abs(denominator) < 1e-15) continue;
            const plus_loss = try objective(histories, plus, config);
            const minus_loss = try objective(histories, minus, config);
            gradient[index] = clamp((plus_loss - minus_loss) / denominator, -config.gradient_clip, config.gradient_clip);
        }

        const step_number: f64 = @floatFromInt(epoch_index + 1);
        const beta1_power = std.math.pow(f64, config.beta1, step_number);
        const beta2_power = std.math.pow(f64, config.beta2, step_number);

        for (0..parameters_mod.weight_count) |index| {
            const grad = gradient[index];
            first_moment[index] = config.beta1 * first_moment[index] + (1.0 - config.beta1) * grad;
            second_moment[index] = config.beta2 * second_moment[index] + (1.0 - config.beta2) * grad * grad;
            const corrected_m = first_moment[index] / (1.0 - beta1_power);
            const corrected_v = second_moment[index] / (1.0 - beta2_power);
            parameters.weights[index] -= config.learning_rate * corrected_m / (@sqrt(corrected_v) + config.epsilon);
        }
        sanitize(&parameters);
    }

    try parameters.validate();
    const final_metrics = try evaluator.evaluate(histories, parameters, evaluation_options);
    return .{
        .parameters = parameters,
        .initial_log_loss = initial_metrics.log_loss,
        .final_log_loss = final_metrics.log_loss,
        .objective_before = before,
        .objective_after = try objective(histories, parameters, config),
        .examples = final_metrics.examples,
        .epochs = config.epochs,
    };
}

test "optimizer produces valid deterministic parameters" {
    const time = @import("../../time.zig");
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .hard, .reviewed_at_ms = 5 * day },
        .{ .rating = .good, .reviewed_at_ms = 9 * day },
        .{ .rating = .again, .reviewed_at_ms = 30 * day },
        .{ .rating = .good, .reviewed_at_ms = 31 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const config: Config = .{ .epochs = 1, .minimum_examples = 1, .learning_rate = 0.001 };
    const result = try optimize(&histories, .{}, config);
    try result.parameters.validate();
    try std.testing.expectEqual(@as(usize, 5), result.examples);
    try std.testing.expect(std.math.isFinite(result.final_log_loss));
}
