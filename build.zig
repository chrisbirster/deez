const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bongo_dependency = b.dependency("bongo", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("deez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("sqlite3", .{});
    mod.addImport("bongo", bongo_dependency.module("bongo"));

    const exe = b.addExecutable(.{
        .name = "deez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "deez", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run Deez");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "deez-benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "deez", .module = mod },
            },
        }),
    });
    b.installArtifact(benchmark_exe);
    const benchmark_run = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step(
        "benchmark",
        "Run deterministic Deez benchmarks; set DEEZ_MONGO_BENCH_URI for MongoDB",
    );
    benchmark_step.dependOn(&benchmark_run.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const mongo_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mongodb_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "deez", .module = mod },
                .{ .name = "bongo", .module = bongo_dependency.module("bongo") },
            },
        }),
    });
    const run_mongo_integration_tests = b.addRunArtifact(mongo_integration_tests);
    const mongo_integration_step = b.step(
        "mongo-integration-test",
        "Run Deez MongoStore integration test against a replica set",
    );
    mongo_integration_step.dependOn(&run_mongo_integration_tests.step);
}
