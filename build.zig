const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const ci = b.option(bool, "running_in_ci", "is running in ci") orelse false;
    options.addOption(bool, "running_in_ci", ci);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const exe = b.addExecutable(.{
            .name = "quicksearch",
            .root_module = exe_mod,
        });
        exe.root_module.addOptions("config", options);
        exe.root_module.addImport("qslib", lib_mod);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const exe_unit_tests = b.addTest(.{
            .root_module = exe_mod,
        });
        exe_unit_tests.root_module.addOptions("config", options);

        const lib_unit_tests = b.addTest(.{
            .root_module = lib_mod,
            .target = target,
            .optimize = optimize,
        });
        lib_unit_tests.root_module.addOptions("config", options);

        const search_mod = b.addModule("searchlib", .{
            .root_source_file = b.path("src/search.zig"),
            .target = target,
            .optimize = optimize,
        });

        const search_unit_tests = b.addTest(.{
            .root_module = search_mod,
            .target = target,
            .optimize = optimize,
            .test_runner = .{
                .path = b.path("src/search/test_runner.zig"),
                .mode = .simple,
            },
        });
        search_unit_tests.root_module.addOptions("config", options);

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        const run_search_unit_tests = b.addRunArtifact(search_unit_tests);
        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_search_unit_tests.step);
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    {
        const benchmark_mod = b.createModule(.{
            .root_source_file = b.path("./src/benchmarks/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const benchmark_exe = b.addExecutable(.{
            .name = "quicksearch-bench",
            .root_module = benchmark_mod,
        });
        benchmark_exe.root_module.addOptions("config", options);
        benchmark_exe.root_module.addImport("qslib", lib_mod);

        b.installArtifact(benchmark_exe);

        const run_benchmarks_cmd = b.addRunArtifact(benchmark_exe);
        run_benchmarks_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_benchmarks_cmd.addArgs(args);
        }

        const run_benchmarks_step = b.step("run-bench", "Run benchmarks");
        run_benchmarks_step.dependOn(&run_benchmarks_cmd.step);
    }
}
