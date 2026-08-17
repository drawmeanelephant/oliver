const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The source commit SHA, embedded into `oliver --version` so a
    // downloaded binary can prove which commit it was built from. CI
    // passes -Dcommit=$GITHUB_SHA; local builds leave it unset and the
    // CLI reports no commit.
    const commit = b.option([]const u8, "commit", "Source commit SHA reported by `oliver --version`") orelse "";

    // The core library. Consumers import it by name (see build.zig.zon);
    // `addModule` registers it as the package's "oliver" module.
    const oliver_mod = b.addModule("oliver", .{
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
    // The version + commit are injected at build time so `oliver --version`
    // is authoritative (consumers assert it against their pin).
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "commit", commit);
    cli_options.addOption([]const u8, "version", packageVersion(b));
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oliver", .module = oliver_mod },
            .{ .name = "build_options", .module = cli_options.createModule() },
        },
    });
    const cli = b.addExecutable(.{
        .name = "oliver",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // CLI argument-parsing tests (src/main.zig) run as part of the ordinary
    // test gate.
    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

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

    // XHTML output-profile tests (tests/xhtml_test.zig) including the
    // mechanical well-formedness gate (tests/xhtml_wellformed.zig).
    const xhtml_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/xhtml_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const run_xhtml_tests = b.addRunArtifact(xhtml_tests);

    // Deterministic mutation-fuzz tests (tests/fuzz.zig) over the public
    // parse API: a fixed-seed PRNG mutates a seed corpus across all three
    // dialects with the extension surface on, asserting the adversarial
    // contracts (no crash, no leak, deterministic output; docs/TESTS.md).
    // Runs in the ordinary test gate with a fixed iteration budget.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oliver", .module = oliver_mod },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    // The stable C ABI example consumer (examples/c_example.c): compiled
    // with the system C compiler against include/oliver.h and the static
    // oliver library, then run to prove the ABI compiles from C and
    // round-trips (docs/C-ABI.md). Self-checking — exits non-zero on any
    // failed assertion, so the step is also the CI gate leg.
    const c_example_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_example_mod.addCSourceFile(.{ .file = b.path("examples/c_example.c"), .flags = &.{"-std=c11"} });
    c_example_mod.addIncludePath(b.path("include"));
    c_example_mod.linkLibrary(lib);
    const c_example = b.addExecutable(.{
        .name = "oliver-c-example",
        .root_module = c_example_mod,
    });
    const c_example_run = b.addRunArtifact(c_example);
    const c_example_step = b.step("c-example-run", "Build and run the C ABI example consumer");
    c_example_step.dependOn(&c_example_run.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_spec_tool_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_xhtml_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
}

/// The package version from build.zig.zon (single source of truth). Zig
/// 0.16 exposes no Build API for it, so read the zon file at configure
/// time and extract `.version = "..."`; fall back to "0.0.0" if the file
/// is unreadable or the marker is missing.
fn packageVersion(b: *std.Build) []const u8 {
    const marker = ".version = \"";
    const zon = std.Io.Dir.readFileAlloc(.cwd(), b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 20)) catch return "0.0.0";
    const start = std.mem.indexOf(u8, zon, marker) orelse return "0.0.0";
    const rest = zon[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.0.0";
    return b.dupe(rest[0..end]);
}
