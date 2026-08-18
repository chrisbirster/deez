const std = @import("std");
const AlgorithmId = @import("algorithm.zig").AlgorithmId;
const Engine = @import("engine.zig").Engine;

pub const Capabilities = struct {
    schedule: bool,
    optimize: bool,
    evaluate: bool,
    simulate: bool,
    retention_analysis: bool,
    replay_history: bool,
};

pub const Status = enum {
    supported,
};

pub const Descriptor = struct {
    algorithm: AlgorithmId,
    name: []const u8,
    status: Status,
    capabilities: Capabilities,
};

pub const fsrs7: Descriptor = .{
    .algorithm = .fsrs7,
    .name = "FSRS-7",
    .status = .supported,
    .capabilities = .{
        .schedule = true,
        .optimize = true,
        .evaluate = true,
        .simulate = true,
        .retention_analysis = true,
        .replay_history = true,
    },
};

pub const supported = [_]Descriptor{fsrs7};

pub fn lookup(algorithm: AlgorithmId) ?Descriptor {
    for (supported) |descriptor| {
        if (descriptor.algorithm.eql(algorithm)) return descriptor;
    }
    return null;
}

pub fn createDefault(algorithm: AlgorithmId) !Engine {
    _ = lookup(algorithm) orelse return error.UnsupportedAlgorithm;
    return Engine.forAlgorithm(algorithm);
}

test "registry resolves FSRS-7 and rejects unpublished FSRS-8" {
    try std.testing.expect(lookup(.fsrs7) != null);
    try std.testing.expect(lookup(.{ .family = .fsrs, .major = 8 }) == null);
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        createDefault(.{ .family = .fsrs, .major = 8 }),
    );
}
