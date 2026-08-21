const std = @import("std");

test {
    _ = @import("mongodb_integration.zig");
    _ = @import("mongodb_scheduler_pinning.zig");
    _ = @import("mongodb_parameter_sets.zig");
    _ = @import("mongodb_durable_history.zig");
}
