//! CommonMark spec-conformance runner.
//!
//! Extracts the normative examples from a CommonMark `spec.txt` (the
//! specification's own test corpus — an explicitly allowed clean-room
//! source) and runs each through Oliver, reporting a per-section
//! scorecard.
//!
//!     zig build spec-conformance -- <path-to-spec.txt> [--gate]
//!
//! Normalization, mirroring the spec's own test driver:
//! - The examples use `→` (U+2192) to represent tab characters; those are
//!   converted to real tabs in both input and expected output.
//! - The expected outputs omit the final newline that block-rendering
//!   renderers emit; one trailing newline on the actual output is ignored
//!   when comparing.
//!
//! Exit status is 0 in report mode; with `--gate`, 1 when any example
//! fails (intended for CI enforcement once the scorecard is where we want
//! it — the block-level constructs are not yet implemented, so the full
//! corpus is expected to fail today).
//!
//! This tool reads files (the spec text) — it is a development harness,
//! not part of the no-filesystem library core.

const std = @import("std");
const oliver = @import("oliver");

const fence = "````````````````````````````````";

const Example = struct {
    /// Current `## ` section (captured only outside example fences, so
    /// `## foo` inside example input never hijacks the tracker).
    section: []const u8,
    input: []const u8,
    expected: []const u8,
    number: usize,
};

/// Replaces the spec's tab arrow `→` with a real tab. Always returns
/// owned memory (even when no arrow is present), so callers can free
/// every `input`/`expected` uniformly.
fn replaceTabs(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x86 and s[i + 2] == 0x92) {
            try out.append(allocator, '\t');
            i += 3;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn isClosingFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, fence) and
        std.mem.indexOfNone(u8, line[fence.len..], " \t\r") == null;
}

/// Parses the example corpus out of a spec.txt. The separator between
/// input and expected output is the first line that is exactly `.`
/// (the curated examples never contain a lone `.` line in their input).
fn parseSpec(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList(Example) {
    var examples = std.ArrayList(Example).empty;
    errdefer {
        for (examples.items) |ex| {
            allocator.free(ex.input);
            allocator.free(ex.expected);
        }
        examples.deinit(allocator);
    }

    var section: []const u8 = "(preamble)";
    var in_example = false;
    var after_sep = false;
    var md = std.ArrayList(u8).empty;
    var expected = std.ArrayList(u8).empty;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!in_example) {
            if (std.mem.startsWith(u8, line, "## ")) {
                section = line[3..];
            } else if (std.mem.eql(u8, line, fence ++ " example")) {
                in_example = true;
                after_sep = false;
                md = std.ArrayList(u8).empty;
                expected = std.ArrayList(u8).empty;
            }
            continue;
        }
        if (!after_sep) {
            // Collect markdown until the `.` separator (the first lone
            // dot line; the curated examples never contain one in input).
            if (std.mem.eql(u8, line, ".")) {
                after_sep = true;
                if (md.items.len > 0) md.items.len -= 1; // drop trailing \n
                continue;
            }
            try md.appendSlice(allocator, line);
            try md.append(allocator, '\n');
            continue;
        }
        // Collect expected output until the closing fence.
        if (isClosingFence(line)) {
            if (expected.items.len > 0) expected.items.len -= 1; // drop trailing \n
            try examples.append(allocator, .{
                .section = section,
                .input = try replaceTabs(allocator, md.items),
                .expected = try replaceTabs(allocator, expected.items),
                .number = examples.items.len + 1,
            });
            md.deinit(allocator);
            expected.deinit(allocator);
            in_example = false;
            continue;
        }
        try expected.appendSlice(allocator, line);
        try expected.append(allocator, '\n');
    }
    return examples;
}

/// Runs one example through Oliver and reports whether the rendered HTML
/// matches the spec's expected bytes (allowing one trailing newline).
fn runExample(gpa: std.mem.Allocator, ex: Example) !bool {
    var result = try oliver.parse(gpa, ex.input, .markdown, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try oliver.html.render(gpa, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(gpa);
    const actual = out.items;
    if (std.mem.eql(u8, ex.expected, actual)) return true;
    if (actual.len == ex.expected.len + 1 and
        std.mem.eql(u8, ex.expected, actual[0..ex.expected.len]) and
        actual[ex.expected.len] == '\n') return true;
    return false;
}

fn printTruncated(writer: anytype, label: []const u8, s: []const u8) !void {
    const max = 160;
    if (s.len <= max) {
        try writer.print("    {s} ({d} bytes):\n    {s}\n", .{ label, s.len, s });
    } else {
        try writer.print("    {s} ({d} bytes, first {d} shown):\n    {s}\n", .{ label, s.len, max, s[0..max] });
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // program name

    var spec_path: ?[]const u8 = null;
    var gate = false;
    var only_section: ?[]const u8 = null;
    var next_is_section = false;
    while (it.next()) |arg| {
        if (next_is_section) {
            only_section = arg;
            next_is_section = false;
        } else if (std.mem.eql(u8, arg, "--gate")) {
            gate = true;
        } else if (std.mem.eql(u8, arg, "--section")) {
            next_is_section = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("spec-conformance: unknown option {s}\n", .{arg});
            return 2;
        } else {
            spec_path = arg;
        }
    }
    const path = spec_path orelse {
        std.debug.print(
            \\usage: spec-conformance <path-to-spec.txt> [--gate] [--section <name>]
            \\  --gate     exit 1 when any example fails (report mode exits 0)
            \\  --section  only run the examples in one `## ` section
            \\
        , .{});
        return 2;
    };

    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(32 * 1024 * 1024)) catch |err| {
        std.debug.print("spec-conformance: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer gpa.free(text);

    var examples = try parseSpec(gpa, text);
    defer {
        for (examples.items) |ex| {
            gpa.free(ex.input);
            gpa.free(ex.expected);
        }
        examples.deinit(gpa);
    }

    // Run every example; keep per-section tallies (first-seen order) and
    // the failure list. Section names alias the spec text (as do the
    // examples' inputs and expected outputs), so nothing here is copied.
    const SectionTally = struct { pass: usize = 0, total: usize = 0 };
    var tallies = std.StringHashMap(SectionTally).init(gpa);
    defer tallies.deinit();
    var sections = std.ArrayList([]const u8).empty;
    defer sections.deinit(gpa);
    var failures = std.ArrayList(Example).empty;
    defer failures.deinit(gpa);

    var pass_total: usize = 0;
    var run_total: usize = 0;
    for (examples.items) |ex| {
        if (only_section) |sect| {
            if (!std.mem.eql(u8, sect, ex.section)) continue;
        }
        run_total += 1;
        const ok = try runExample(gpa, ex);
        const gop = try tallies.getOrPut(ex.section);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            try sections.append(gpa, ex.section);
        }
        gop.value_ptr.total += 1;
        if (ok) {
            gop.value_ptr.pass += 1;
            pass_total += 1;
        } else {
            try failures.append(gpa, ex);
        }
    }

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out_writer.interface;

    try w.print("CommonMark spec-conformance: {d}/{d} examples pass\n", .{ pass_total, run_total });
    try w.print("\nPer-section scorecard:", .{});
    for (sections.items) |key| {
        const t = tallies.get(key).?;
        const pct: usize = if (t.total == 0) 0 else (100 * t.pass) / t.total;
        try w.print("\n  {s:>44}  {d:>3}/{d:<3}  {d:>3}%", .{ key, t.pass, t.total, pct });
    }
    try w.print("\n", .{});

    if (failures.items.len > 0) {
        try w.print("\nFailures ({d}):\n", .{failures.items.len});
        for (failures.items, 0..) |ex, idx| {
            if (idx >= 40) {
                try w.print("  ... and {d} more\n", .{failures.items.len - 40});
                break;
            }
            try w.print("  #{d} [{s}]\n", .{ ex.number, ex.section });
            try printTruncated(w, "input", ex.input);
            try printTruncated(w, "expected", ex.expected);
            // Re-run to show what Oliver actually produced.
            var result = try oliver.parse(gpa, ex.input, .markdown, .{});
            defer result.deinit();
            var aw = std.Io.Writer.Allocating.init(gpa);
            defer aw.deinit();
            try oliver.html.render(gpa, &aw.writer, &result.document, .{});
            var out = aw.toArrayList();
            defer out.deinit(gpa);
            try printTruncated(w, "actual", out.items);
        }
    }

    out_writer.flush() catch {};
    if (gate and failures.items.len > 0) return 1;
    return 0;
}
