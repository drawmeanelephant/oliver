//! CommonMark 0.31.2 conformance scorecard and classified expectation gate.
//!
//!     zig build spec-conformance -- <spec.txt> [--gate] [--section <name>]
//!
//! The classified gate is intentionally stricter than a frozen pass count:
//! supported examples must pass, not-yet examples must still fail (an
//! unexpected pass requires review and reclassification), and named
//! divergences must retain their pinned Oliver output. The canonical corpus is
//! bound by version, exact byte count, SHA-256 digest, and example count.

const std = @import("std");
const oliver = @import("oliver");
const expectations = @import("commonmark_expectations.zig");

const fence = "````````````````````````````````";
const max_spec_bytes = 32 * 1024 * 1024;

const CorpusError = error{
    MissingSeparator,
    UnterminatedExample,
    NestedExample,
    UnexpectedClosingFence,
    EmptySection,
    ByteCountMismatch,
    ExampleCountMismatch,
    DigestMismatch,
    InvalidManifest,
};

const Example = struct {
    section: []const u8,
    input: []const u8,
    expected: []const u8,
    number: usize,
};

const ParseResult = struct {
    examples: std.ArrayList(Example),

    fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.examples.items) |ex| {
            allocator.free(ex.input);
            allocator.free(ex.expected);
        }
        self.examples.deinit(allocator);
    }
};

const RenderResult = struct {
    bytes: std.ArrayList(u8),
    matches_spec: bool,

    fn deinit(self: *RenderResult, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
};

const Outcome = enum {
    expected_pass,
    expected_not_yet,
    expected_divergence,
    regression,
    unexpected_pass,
    changed_divergence,

    fn isMismatch(self: Outcome) bool {
        return switch (self) {
            .expected_pass, .expected_not_yet, .expected_divergence => false,
            .regression, .unexpected_pass, .changed_divergence => true,
        };
    }
};

const Counts = struct {
    supported: usize = 0,
    not_yet: usize = 0,
    divergence: usize = 0,
    expected_pass: usize = 0,
    expected_not_yet: usize = 0,
    expected_divergence: usize = 0,
    regression: usize = 0,
    unexpected_pass: usize = 0,
    changed_divergence: usize = 0,

    fn mismatches(self: Counts) usize {
        return self.regression + self.unexpected_pass + self.changed_divergence;
    }
};

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

fn isOpeningFence(line: []const u8) bool {
    return std.mem.eql(u8, line, fence ++ " example");
}

fn isClosingFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, fence) and
        std.mem.indexOfNone(u8, line[fence.len..], " \t\r") == null;
}

/// Extracts normative examples and rejects malformed or truncated fences.
/// `# ` and `## ` headings are captured only outside examples, so example
/// input cannot hijack the section tracker.
fn parseSpec(allocator: std.mem.Allocator, text: []const u8) !ParseResult {
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
    var after_separator = false;
    var md = std.ArrayList(u8).empty;
    defer md.deinit(allocator);
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!in_example) {
            if (std.mem.startsWith(u8, line, "## ")) {
                if (line.len == 3) return CorpusError.EmptySection;
                section = line[3..];
            } else if (std.mem.startsWith(u8, line, "# ")) {
                if (line.len == 2) return CorpusError.EmptySection;
                section = line[2..];
            } else if (isOpeningFence(line)) {
                in_example = true;
                after_separator = false;
                md.clearRetainingCapacity();
                expected.clearRetainingCapacity();
            } else if (isClosingFence(line)) {
                return CorpusError.UnexpectedClosingFence;
            }
            continue;
        }

        if (isOpeningFence(line)) return CorpusError.NestedExample;
        if (!after_separator) {
            if (std.mem.eql(u8, line, ".")) {
                after_separator = true;
                if (md.items.len > 0) md.items.len -= 1;
                continue;
            }
            if (isClosingFence(line)) return CorpusError.MissingSeparator;
            try md.appendSlice(allocator, line);
            try md.append(allocator, '\n');
            continue;
        }

        if (isClosingFence(line)) {
            if (expected.items.len > 0) expected.items.len -= 1;
            const input = try replaceTabs(allocator, md.items);
            errdefer allocator.free(input);
            const expected_owned = try replaceTabs(allocator, expected.items);
            errdefer allocator.free(expected_owned);
            try examples.append(allocator, .{
                .section = section,
                .input = input,
                .expected = expected_owned,
                .number = examples.items.len + 1,
            });
            in_example = false;
            continue;
        }
        try expected.appendSlice(allocator, line);
        try expected.append(allocator, '\n');
    }
    if (in_example) return CorpusError.UnterminatedExample;
    return .{ .examples = examples };
}

fn actualMatchesExpected(expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    return actual.len == expected.len + 1 and
        std.mem.eql(u8, expected, actual[0..expected.len]) and
        actual[expected.len] == '\n';
}

fn runExample(gpa: std.mem.Allocator, ex: Example) !RenderResult {
    var result = try oliver.parse(gpa, ex.input, .markdown, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try oliver.html.render(gpa, &aw.writer, &result.document, .{});
    const bytes = aw.toArrayList();
    return .{
        .matches_spec = actualMatchesExpected(ex.expected, bytes.items),
        .bytes = bytes,
    };
}

fn classify(class: expectations.Class, matches_spec: bool, actual: []const u8, number: usize) Outcome {
    return switch (class) {
        .supported => if (matches_spec) .expected_pass else .regression,
        .not_yet => if (matches_spec) .unexpected_pass else .expected_not_yet,
        .divergence => if (matches_spec)
            .changed_divergence
        else if (expectations.divergenceFor(number)) |divergence|
            if (std.mem.eql(u8, divergence.actual, actual)) .expected_divergence else .changed_divergence
        else
            .changed_divergence,
    };
}

fn classForRanges(ranges: []const expectations.Range, number: usize) ?expectations.Class {
    for (ranges) |range| {
        if (number >= range.first and number <= range.last) return range.class;
    }
    return null;
}

fn validateManifestData(
    ranges: []const expectations.Range,
    divergences: []const expectations.Divergence,
    expected_count: usize,
) !Counts {
    if (ranges.len == 0) return CorpusError.InvalidManifest;
    var next: usize = 1;
    var counts = Counts{};
    for (ranges) |range| {
        if (range.first != next or range.first > range.last or range.last > expected_count)
            return CorpusError.InvalidManifest;
        const len = range.last - range.first + 1;
        switch (range.class) {
            .supported => counts.supported += len,
            .not_yet => counts.not_yet += len,
            .divergence => counts.divergence += len,
        }
        next = range.last + 1;
    }
    if (next != expected_count + 1) return CorpusError.InvalidManifest;

    if (divergences.len != counts.divergence) return CorpusError.InvalidManifest;
    var previous: usize = 0;
    for (divergences) |divergence| {
        if (divergence.example <= previous or
            classForRanges(ranges, divergence.example) != .divergence or
            divergence.name.len == 0 or divergence.rationale.len == 0)
            return CorpusError.InvalidManifest;
        previous = divergence.example;
    }
    return counts;
}

fn validateManifest(expected_count: usize) !Counts {
    return validateManifestData(&expectations.ranges, &expectations.divergences, expected_count);
}

fn verifyOfficialCorpus(text: []const u8, parsed_count: usize) !void {
    if (text.len != expectations.spec_byte_count) return CorpusError.ByteCountMismatch;
    if (parsed_count != expectations.example_count) return CorpusError.ExampleCountMismatch;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, expectations.spec_sha256_hex, &hex)) return CorpusError.DigestMismatch;
}

fn printTruncated(writer: anytype, label: []const u8, s: []const u8) !void {
    const max = 160;
    if (s.len <= max) {
        try writer.print("    {s} ({d} bytes):\n    {s}\n", .{ label, s.len, s });
    } else {
        try writer.print("    {s} ({d} bytes, first {d} shown):\n    {s}\n", .{ label, s.len, max, s[0..max] });
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: spec-conformance <path-to-spec.txt> [--gate] [--section <name>]
        \\  --gate     enforce the classified CommonMark 0.31.2 expectations
        \\  --section  report one exact specification heading (cannot be combined with --gate)
        \\
    , .{});
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    var spec_path: ?[]const u8 = null;
    var gate = false;
    var only_section: ?[]const u8 = null;
    var next_is_section = false;
    while (args.next()) |arg| {
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
        } else if (spec_path != null) {
            std.debug.print("spec-conformance: multiple spec paths supplied\n", .{});
            return 2;
        } else {
            spec_path = arg;
        }
    }
    if (next_is_section or (gate and only_section != null)) {
        printUsage();
        return 2;
    }
    const path = spec_path orelse {
        printUsage();
        return 2;
    };

    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_spec_bytes)) catch |err| {
        std.debug.print("spec-conformance: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer gpa.free(text);

    var parsed = parseSpec(gpa, text) catch |err| {
        std.debug.print("spec-conformance: malformed corpus: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer parsed.deinit(gpa);

    verifyOfficialCorpus(text, parsed.examples.items.len) catch |err| {
        std.debug.print(
            "spec-conformance: corpus identity mismatch for CommonMark {s}: {s}\nexpected {d} bytes, {d} examples, SHA-256 {s}\nsource: {s}\n",
            .{ expectations.spec_version, @errorName(err), expectations.spec_byte_count, expectations.example_count, expectations.spec_sha256_hex, expectations.spec_url },
        );
        return 2;
    };
    var counts = validateManifest(expectations.example_count) catch |err| {
        std.debug.print("spec-conformance: invalid expectation manifest: {s}\n", .{@errorName(err)});
        return 2;
    };

    const SectionTally = struct { pass: usize = 0, total: usize = 0 };
    var tallies = std.StringHashMap(SectionTally).init(gpa);
    defer tallies.deinit();
    var sections = std.ArrayList([]const u8).empty;
    defer sections.deinit(gpa);
    const Mismatch = struct { ex: Example, outcome: Outcome, actual: []const u8 };
    var mismatches = std.ArrayList(Mismatch).empty;
    defer {
        for (mismatches.items) |mismatch| gpa.free(mismatch.actual);
        mismatches.deinit(gpa);
    }
    const NormativeFailure = struct { ex: Example, class: expectations.Class, actual: []const u8 };
    var failures = std.ArrayList(NormativeFailure).empty;
    defer {
        for (failures.items) |failure| gpa.free(failure.actual);
        failures.deinit(gpa);
    }

    var pass_total: usize = 0;
    var run_total: usize = 0;
    for (parsed.examples.items) |ex| {
        if (only_section) |section| {
            if (!std.mem.eql(u8, section, ex.section)) continue;
        }
        run_total += 1;
        var rendered = try runExample(gpa, ex);
        defer rendered.deinit(gpa);
        if (rendered.matches_spec) pass_total += 1;

        const class = expectations.classFor(ex.number) orelse {
            std.debug.print("spec-conformance: example #{d} is not classified\n", .{ex.number});
            return 2;
        };
        if (!gate and !rendered.matches_spec) {
            try failures.append(gpa, .{
                .ex = ex,
                .class = class,
                .actual = try gpa.dupe(u8, rendered.bytes.items),
            });
        }
        const outcome = classify(class, rendered.matches_spec, rendered.bytes.items, ex.number);
        switch (outcome) {
            .expected_pass => counts.expected_pass += 1,
            .expected_not_yet => counts.expected_not_yet += 1,
            .expected_divergence => counts.expected_divergence += 1,
            .regression => counts.regression += 1,
            .unexpected_pass => counts.unexpected_pass += 1,
            .changed_divergence => counts.changed_divergence += 1,
        }
        if (outcome.isMismatch()) {
            try mismatches.append(gpa, .{
                .ex = ex,
                .outcome = outcome,
                .actual = try gpa.dupe(u8, rendered.bytes.items),
            });
        }

        const gop = try tallies.getOrPut(ex.section);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            try sections.append(gpa, ex.section);
        }
        gop.value_ptr.total += 1;
        if (rendered.matches_spec) gop.value_ptr.pass += 1;
    }

    if (only_section != null and run_total == 0) {
        std.debug.print("spec-conformance: section not found: {s}\n", .{only_section.?});
        return 2;
    }

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    const writer = &stdout.interface;
    try writer.print(
        "CommonMark {s} spec-conformance: {d}/{d} examples pass (SHA-256 {s})\n",
        .{ expectations.spec_version, pass_total, run_total, expectations.spec_sha256_hex },
    );
    try writer.print("\nPer-section scorecard:", .{});
    for (sections.items) |section| {
        const tally = tallies.get(section).?;
        const percent: usize = if (tally.total == 0) 0 else (100 * tally.pass) / tally.total;
        try writer.print("\n  {s:>44}  {d:>3}/{d:<3}  {d:>3}%", .{ section, tally.pass, tally.total, percent });
    }
    try writer.print("\n", .{});

    if (failures.items.len > 0) {
        try writer.print("\nNormative failures ({d}):\n", .{failures.items.len});
        for (failures.items, 0..) |failure, index| {
            if (index >= 40) {
                try writer.print("  ... and {d} more\n", .{failures.items.len - 40});
                break;
            }
            try writer.print(
                "  #{d} [{s}] class={s}\n",
                .{ failure.ex.number, failure.ex.section, @tagName(failure.class) },
            );
            if (expectations.divergenceFor(failure.ex.number)) |divergence| {
                try writer.print("    divergence: {s} ({s})\n", .{ divergence.name, divergence.rationale });
            }
            try printTruncated(writer, "input", failure.ex.input);
            try printTruncated(writer, "expected", failure.ex.expected);
            try printTruncated(writer, "actual", failure.actual);
        }
    }

    if (only_section == null) {
        try writer.print(
            "\nExpectations: {d} supported, {d} not-yet, {d} named divergence\n",
            .{ counts.supported, counts.not_yet, counts.divergence },
        );
        try writer.print(
            "Observed: {d} expected passes, {d} expected not-yet failures, {d} expected divergences\n",
            .{ counts.expected_pass, counts.expected_not_yet, counts.expected_divergence },
        );
        try writer.print(
            "Gate mismatches: {d} regressions, {d} unexpected passes, {d} changed divergences\n",
            .{ counts.regression, counts.unexpected_pass, counts.changed_divergence },
        );
        try writer.print("Named divergences:\n", .{});
        for (expectations.divergences) |divergence| {
            try writer.print(
                "  #{d}: {s} ({s})\n",
                .{ divergence.example, divergence.name, divergence.rationale },
            );
        }
    }

    if (mismatches.items.len > 0) {
        try writer.print("\nExpectation mismatches ({d}):\n", .{mismatches.items.len});
        for (mismatches.items) |mismatch| {
            try writer.print("  #{d} [{s}] {s}\n", .{ mismatch.ex.number, mismatch.ex.section, @tagName(mismatch.outcome) });
            try printTruncated(writer, "input", mismatch.ex.input);
            try printTruncated(writer, "expected", mismatch.ex.expected);
            try printTruncated(writer, "actual", mismatch.actual);
        }
    }

    stdout.flush() catch {};
    if (gate and counts.mismatches() > 0) return 1;
    return 0;
}

fn syntheticSpec(body: []const u8) []const u8 {
    return body;
}

test "parseSpec accepts synthetic examples, sections, CRLF, and tab arrows" {
    const allocator = std.testing.allocator;
    const text = syntheticSpec(
        "# Alpha\r\n" ++
            fence ++ " example\r\n" ++
            "a→b\r\n.\r\n<p>a→b</p>\r\n" ++ fence ++ "\r\n" ++
            "## Beta\n" ++ fence ++ " example\n.\n\n" ++ fence ++ "\n",
    );
    var parsed = try parseSpec(allocator, text);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.examples.items.len);
    try std.testing.expectEqualStrings("Alpha", parsed.examples.items[0].section);
    try std.testing.expectEqualStrings("a\tb", parsed.examples.items[0].input);
    try std.testing.expectEqualStrings("<p>a\tb</p>", parsed.examples.items[0].expected);
    try std.testing.expectEqualStrings("Beta", parsed.examples.items[1].section);
    try std.testing.expectEqualStrings("", parsed.examples.items[1].input);
    try std.testing.expectEqualStrings("", parsed.examples.items[1].expected);
}

test "parseSpec rejects missing separator, truncation, nesting, and empty section" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, expected: anyerror }{
        .{ .text = fence ++ " example\nx\n" ++ fence ++ "\n", .expected = CorpusError.MissingSeparator },
        .{ .text = fence ++ " example\nx\n.\n<p>x</p>\n", .expected = CorpusError.UnterminatedExample },
        .{ .text = fence ++ " example\nx\n" ++ fence ++ " example\n", .expected = CorpusError.NestedExample },
        .{ .text = fence ++ "\n", .expected = CorpusError.UnexpectedClosingFence },
        .{ .text = "## \n", .expected = CorpusError.EmptySection },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, parseSpec(allocator, case.text));
    }
}

test "official identity rejects wrong byte count, example count, and digest" {
    try std.testing.expectError(CorpusError.ByteCountMismatch, verifyOfficialCorpus("x", 1));

    const wrong = try std.testing.allocator.alloc(u8, expectations.spec_byte_count);
    defer std.testing.allocator.free(wrong);
    @memset(wrong, 0);
    try std.testing.expectError(CorpusError.ExampleCountMismatch, verifyOfficialCorpus(wrong, 1));
    try std.testing.expectError(CorpusError.DigestMismatch, verifyOfficialCorpus(wrong, expectations.example_count));
}

test "expectation partition is complete and named divergences are exact" {
    const counts = try validateManifest(expectations.example_count);
    try std.testing.expectEqual(expectations.example_count, counts.supported + counts.not_yet + counts.divergence);
    // Steady state after the thematic-break/Setext, fenced-code, and list
    // milestones: 546 supported, 106 not-yet, and the former ATX
    // trailing-backslash divergence (example 646) now conforms. These pins
    // move only with a reviewed manifest change.
    try std.testing.expectEqual(@as(usize, 546), counts.supported);
    try std.testing.expectEqual(@as(usize, 106), counts.not_yet);
    try std.testing.expectEqual(@as(usize, 0), counts.divergence);
    try std.testing.expectEqual(expectations.Class.supported, expectations.classFor(646).?);
    try std.testing.expect(expectations.classFor(0) == null);
    try std.testing.expect(expectations.classFor(expectations.example_count + 1) == null);
}

test "manifest validation rejects gaps overlaps and malformed divergence records" {
    const valid_ranges = [_]expectations.Range{
        .{ .first = 1, .last = 1, .class = .supported },
        .{ .first = 2, .last = 2, .class = .not_yet },
    };
    _ = try validateManifestData(&valid_ranges, &.{}, 2);

    const gap = [_]expectations.Range{
        .{ .first = 1, .last = 1, .class = .supported },
        .{ .first = 3, .last = 3, .class = .not_yet },
    };
    try std.testing.expectError(CorpusError.InvalidManifest, validateManifestData(&gap, &.{}, 3));

    const overlap = [_]expectations.Range{
        .{ .first = 1, .last = 2, .class = .supported },
        .{ .first = 2, .last = 3, .class = .not_yet },
    };
    try std.testing.expectError(CorpusError.InvalidManifest, validateManifestData(&overlap, &.{}, 3));

    const divergence_range = [_]expectations.Range{
        .{ .first = 1, .last = 1, .class = .divergence },
    };
    try std.testing.expectError(CorpusError.InvalidManifest, validateManifestData(&divergence_range, &.{}, 1));
    const unnamed = [_]expectations.Divergence{.{
        .example = 1,
        .name = "",
        .rationale = "reason",
        .actual = "output",
    }};
    try std.testing.expectError(CorpusError.InvalidManifest, validateManifestData(&divergence_range, &unnamed, 1));
}

test "classification exposes regressions unexpected passes and changed divergences" {
    try std.testing.expectEqual(Outcome.expected_pass, classify(.supported, true, "", 1));
    try std.testing.expectEqual(Outcome.regression, classify(.supported, false, "", 1));
    try std.testing.expectEqual(Outcome.expected_not_yet, classify(.not_yet, false, "", 1));
    try std.testing.expectEqual(Outcome.unexpected_pass, classify(.not_yet, true, "", 1));
    // No named divergences remain (example 646 now conforms), so a
    // `.divergence` class is always a change: a spec-matching output must
    // not be classified divergence, and with no pinned record any other
    // output is a change too. The expected_divergence outcome is asserted
    // by whichever future milestone reintroduces a divergence record.
    try std.testing.expect(expectations.divergenceFor(646) == null);
    try std.testing.expectEqual(Outcome.changed_divergence, classify(.divergence, true, "", 646));
    try std.testing.expectEqual(Outcome.changed_divergence, classify(.divergence, false, "<h3>foo\\</h3>\n", 646));
    try std.testing.expectEqual(Outcome.changed_divergence, classify(.divergence, false, "different", 646));
}

test "expected comparison permits exactly one generated trailing newline" {
    try std.testing.expect(actualMatchesExpected("<p>x</p>", "<p>x</p>\n"));
    try std.testing.expect(actualMatchesExpected("<p>x</p>", "<p>x</p>"));
    try std.testing.expect(!actualMatchesExpected("<p>x</p>", "<p>x</p>\n\n"));
}
