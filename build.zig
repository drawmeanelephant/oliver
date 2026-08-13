const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core library. Consumers import it by name (see build.zig.zon).
    const oliver_mod = b.createModule(.{
        .root_source_file = b.path("src/oliver.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library: no libc, no host dependencies. The future C ABI will
    // be layered on top of this; for now the library is pure Zig.
    const lib = b.addLibrary(.{
        .name = "oliver",
        .root_module = oliver_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Provisional CLI: a thin adapter over the library (stdin -> stdout).
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oliver", .module = oliver_mod },
        },
    });
    const cli = b.addExecutable(.{
        .name = "oliver",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    const cli_run = b.addRunArtifact(cli);
    if (b.args) |args| cli_run.addArgs(args);
    const run_step = b.step("run", "Run the oliver CLI");
    run_step.dependOn(&cli_run.step);

    // CommonMark spec-conformance harness: runs every example in a
    // spec.txt through the library and prints a per-section scorecard.
    // Development tool only (reads files; the library core does not).
    const spec_tool = b.addExecutable(.{
        .name = "spec-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spec_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const spec_run = b.addRunArtifact(spec_tool);
    if (b.args) |args| spec_run.addArgs(args);
    const spec_step = b.step("spec-conformance", "Run the CommonMark spec-conformance scorecard");
    spec_step.dependOn(&spec_run.step);

    // Cooklang canonical conformance harness: runs the official cooklang/spec
    // corpus (bound by digest) through oliver.cooklang.parse. Development
    // tool only (reads files; the library core does not).
    const cook_tool = b.addExecutable(.{
        .name = "cooklang-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cooklang_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const cook_run = b.addRunArtifact(cook_tool);
    // Default to the vendored corpus (pinned, digest-bound) so a bare
    // `zig build cooklang-conformance` runs the wall; pass a path to
    // check a freshly fetched copy instead.
    if (b.args) |args| cook_run.addArgs(args) else cook_run.addArg("tests/cooklang/canonical.yaml");
    const cook_step = b.step("cooklang-conformance", "Run the Cooklang canonical conformance scorecard");
    cook_step.dependOn(&cook_run.step);

    // Synthetic unit tests for corpus parsing, identity checks, the complete
    // expectation partition, and outcome classification. These do not need a
    // downloaded spec.txt and therefore run as part of the ordinary test gate.
    const spec_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spec_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const run_spec_tool_tests = b.addRunArtifact(spec_tool_tests);
    const spec_test_step = b.step("spec-conformance-test", "Test the CommonMark conformance harness");
    spec_test_step.dependOn(&run_spec_tool_tests.step);

    // Unit tests embedded in the library modules.
    const lib_tests = b.addTest(.{
        .root_module = oliver_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Fixture-driven tests (tests/fixtures_test.zig).
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_spec_tool_tests.step);
}
