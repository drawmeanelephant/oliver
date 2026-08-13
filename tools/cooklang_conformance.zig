//! Cooklang canonical conformance harness.
//!
//!     zig build cooklang-conformance [-- <canonical.yaml>] [--gate]
//!
//! Runs every test in the official `cooklang/spec` canonical corpus
//! (version 7, 60 tests, commit `6c4788644004e604ae1da110af6d2400e3c9c7b0`)
//! through `oliver.cooklang.parse` and compares the typed Recipe against
//! the expected steps/metadata. With no path argument the vendored corpus
//! `tests/cooklang/canonical.yaml` (pinned, digest-bound) is used; a path
//! may be given to check a freshly fetched copy instead.
//!
//! The corpus is bound by exact byte count and SHA-256 digest, and the
//! expected `result:` blocks are re-serialized with the same canonical
//! text form the harness derives from the Recipe — so a mismatch is a real
//! semantic difference, not a formatting one. Quantities compare as raw
//! scalars (the model's numeric view formats `1/2` as `0.5`, matching the
//! corpus's `quantity: 0.5`), and defaults follow the corpus: ingredients
//! without braces get `"some"`, cookware gets `1`, timers get `""`.
//!
//! Metadata is compared as line-oriented scalars (key: value pairs) — the
//! harness does not parse YAML, and neither does the library.
//!
//! Provenance: https://github.com/cooklang/spec at 6c478864, tests/
//! README.md describes the corpus; docs/COOKLANG.md and docs/CLEANROOM.md
//! session 21 record the full policy.

const std = @import("std");
const oliver = @import("oliver");

const corpus_sha256 = "e3dc4fdbc5d883add6b24a971fc5fc07e68edc26d5df5084cf849d649cda98de";
const corpus_bytes: usize = 15836;
const corpus_tests: usize = 60;

const ConformanceError = error{
    MissingCorpus,
    DigestMismatch,
    ByteCountMismatch,
    TestCountMismatch,
    ConformanceFailed,
    OutOfMemory,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // program name
    var gate = false;
    var path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--gate")) {
            gate = true;
        } else if (path == null) {
            path = a;
        }
    }

    const corpus_path = path orelse "tests/cooklang/canonical.yaml";
    const corpus = std.Io.Dir.cwd().readFileAlloc(init.io, corpus_path, allocator, .limited(64 * 1024 * 1024)) catch |e| {
        std.debug.print("cannot read {s}: {s}\n", .{ corpus_path, @errorName(e) });
        return 1;
    };
    defer allocator.free(corpus);

    if (corpus.len != corpus_bytes) {
        std.debug.print("corpus byte count mismatch: expected {d}, found {d}\n", .{ corpus_bytes, corpus.len });
        return 1;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(corpus, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, corpus_sha256)) {
        std.debug.print("corpus digest mismatch: expected {s}, found {s}\n", .{ corpus_sha256, hex });
        return 1;
    }

    var tests = try parseTests(allocator, corpus);
    defer tests.deinit(allocator);
    if (tests.items.len != corpus_tests) {
        std.debug.print("test count mismatch: expected {d}, found {d}\n", .{ corpus_tests, tests.items.len });
        return 1;
    }

    var passed: usize = 0;
    var mismatched = std.ArrayList([]const u8).empty;
    defer mismatched.deinit(allocator);

    for (tests.items) |t| {
        var result = try oliver.cooklang.parse(allocator, t.source, .{});
        defer result.deinit();
        const actual = try serializeRecipe(allocator, result.recipe);
        defer allocator.free(actual);
        const expected = try serializeExpected(allocator, t.expected);
        defer allocator.free(expected);
        if (std.mem.eql(u8, actual, expected)) {
            passed += 1;
        } else {
            const name = try allocator.dupe(u8, t.name);
            try mismatched.append(allocator, name);
            std.debug.print("FAIL {s}\n  expected: {s}\n  actual:   {s}\n", .{ t.name, expected, actual });
        }
    }

    std.debug.print("\nCooklang canonical conformance: {d}/{d} passed\n", .{ passed, tests.items.len });
    for (mismatched.items) |n| allocator.free(n);
    if (passed != tests.items.len) return 1;
    if (gate) std.debug.print("gate: clean\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// Corpus parsing (a minimal reader for this exact corpus shape).
// ---------------------------------------------------------------------------

const Test = struct {
    name: []const u8,
    source: []const u8,
    expected: []const u8, // the raw `result:` block
};

const TestList = std.ArrayList(Test);

const TestListOwned = struct {
    items: []Test,

    fn deinit(self: *TestListOwned, allocator: std.mem.Allocator) void {
        for (self.items) |t| {
            allocator.free(t.name);
            allocator.free(t.source);
            allocator.free(t.expected);
        }
        allocator.free(self.items);
    }
};

fn isTestHeader(line: []const u8) bool {
    if (line.len < 6) return false;
    if (line[0] != ' ' or line[1] != ' ') return false;
    if (line[2] == ' ') return false;
    if (line[line.len - 1] != ':') return false;
    var i: usize = 2;
    while (i + 1 < line.len and line[i] != ':') : (i += 1) {}
    return i == line.len - 1;
}

fn isAllSpaces(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ') return false;
    }
    return true;
}

fn parseTests(allocator: std.mem.Allocator, corpus: []const u8) !TestListOwned {
    var tests = TestList.empty;
    errdefer {
        for (tests.items) |t| {
            allocator.free(t.name);
            allocator.free(t.source);
            allocator.free(t.expected);
        }
        tests.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var all = std.ArrayList([]const u8).empty;
    while (lines.next()) |l| try all.append(allocator, l);
    defer all.deinit(allocator);

    var i: usize = 0;
    while (i < all.items.len) : (i += 1) {
        if (!isTestHeader(all.items[i])) continue;
        const name = all.items[i][2 .. all.items[i].len - 1];

        // Find `    source: |` and capture its indented block.
        var j = i + 1;
        var source = std.ArrayList(u8).empty;
        var result_start: usize = all.items.len;
        while (j < all.items.len and !isTestHeader(all.items[j])) : (j += 1) {
            if (std.mem.startsWith(u8, all.items[j], "    source: |")) {
                var k = j + 1;
                while (k < all.items.len and !isTestHeader(all.items[k])) : (k += 1) {
                    const sl = all.items[k];
                    if (sl.len == 0) {
                        try source.append(allocator, '\n');
                        continue;
                    }
                    if (sl.len < 6 or !isAllSpaces(sl[0..6])) break;
                    try source.appendSlice(allocator, sl[6..]);
                    try source.append(allocator, '\n');
                }
                result_start = k;
                break;
            }
        }

        // The result block runs from `result_start` to the next header.
        var expected = std.ArrayList(u8).empty;
        var k = result_start;
        while (k < all.items.len and !isTestHeader(all.items[k])) : (k += 1) {
            try expected.appendSlice(allocator, all.items[k]);
            try expected.append(allocator, '\n');
        }
        i = k - 1;

        try tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .source = try source.toOwnedSlice(allocator),
            .expected = try expected.toOwnedSlice(allocator),
        });
    }
    return .{ .items = try tests.toOwnedSlice(allocator) };
}

// ---------------------------------------------------------------------------
// Canonical serialization.
// ---------------------------------------------------------------------------

/// A tiny growable output buffer with the writer methods the serializers
/// need (Zig 0.16's ArrayList has no `writer()`).
const Buf = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn writeAll(self: *Buf, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }

    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.a, fmt, args);
        defer self.a.free(s);
        try self.buf.appendSlice(self.a, s);
    }

    fn done(self: *Buf) ![]const u8 {
        return self.buf.toOwnedSlice(self.a);
    }
};

/// Formats a quantity as the corpus does: numeric views become numbers
/// (`1/2` -> `0.5`), everything else stays its source text. `default` is
/// applied when the token carried no explicit quantity (`"some"` for
/// ingredients, `1` for cookware, `""` for timers).
fn formatQuantity(w: *Buf, q: ?[]const u8, numeric: ?oliver.cooklang.Quantity, default: []const u8) !void {
    if (q == null or q.?.len == 0) {
        try w.writeAll(default);
        return;
    }
    if (numeric) |n| switch (n) {
        .int => |v| try w.print("{d}", .{v}),
        .decimal => |v| try w.print("{d}", .{v}),
        .fraction => |f| try w.print("{d}", .{@as(f64, @floatFromInt(f.num)) / @as(f64, @floatFromInt(f.den))}),
    } else {
        try w.writeAll(q.?);
    }
}

fn serializeRecipe(allocator: std.mem.Allocator, recipe: oliver.cooklang.Recipe) ![]const u8 {
    var out = Buf{ .a = allocator };
    var first_step = true;
    for (recipe.blocks) |block| {
        switch (block) {
            .step => |step| {
                if (!first_step) try out.writeAll(" / ");
                first_step = false;
                var first_part = true;
                for (step.parts) |part| {
                    if (!first_part) try out.writeAll(" ; ");
                    first_part = false;
                    switch (part) {
                        .text => |t| try out.print("T:{s}", .{t.text}),
                        .ingredient => |ig| {
                            try out.print("I:{s}|", .{ig.name});
                            try formatQuantity(&out, ig.quantity, ig.numeric, "some");
                            try out.writeAll("|");
                            try out.writeAll(ig.units orelse "");
                        },
                        .cookware => |cw| {
                            // Cookware never carries units (the corpus
                            // always emits `units: ""`).
                            try out.print("C:{s}|", .{cw.name});
                            try formatQuantity(&out, cw.quantity, cw.numeric, "1");
                            try out.writeAll("|");
                        },
                        .timer => |tm| {
                            try out.writeAll("M:");
                            try formatQuantity(&out, tm.quantity, tm.numeric, "");
                            try out.print("|{s}|{s}", .{ tm.units orelse "", tm.name });
                        },
                        .line_break => try out.writeAll("T:\n"),
                    }
                }
            },
            .note => |n| try out.print("N:{s}", .{n.text}),
            .section => |s| try out.print("S:{s}", .{s.name}),
        }
    }
    try out.writeAll(" // ");
    if (recipe.frontmatter) |fm| {
        const pairs = try metadataPairs(allocator, fm.raw);
        defer allocator.free(pairs);
        std.mem.sort(KeyValue, pairs, {}, lessThan);
        for (pairs, 0..) |kv, idx| {
            if (idx > 0) try out.writeAll("\n");
            try out.print("{s}={s}", .{ kv.key, kv.value });
        }
    }
    return out.done();
}

const KeyValue = struct { key: []const u8, value: []const u8 };

fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Parses line-oriented `key: value` scalars (the metadata subset both the
/// corpus and the raw front matter payload share). No YAML semantics.
/// Parses line-oriented `key: value` scalars (the metadata subset both the
/// corpus and the raw front matter payload share). No YAML semantics. The
/// returned slices borrow from `raw`.
fn metadataPairs(allocator: std.mem.Allocator, raw: []const u8) ![]KeyValue {
    var pairs = std.ArrayList(KeyValue).empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        try pairs.append(allocator, .{ .key = trimQuotes(key), .value = trimQuotes(value) });
    }
    return pairs.toOwnedSlice(allocator);
}

fn trimQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn serializeExpected(allocator: std.mem.Allocator, block: []const u8) ![]const u8 {
    var out = Buf{ .a = allocator };

    var lines = std.mem.splitScalar(u8, block, '\n');
    var step_parts = std.ArrayList(PartFields).empty; // parts of the current step
    var first_step = true;
    var first_part = true;
    var metadata = std.ArrayList(KeyValue).empty;
    var in_metadata = false;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "      steps: []")) {
            // No steps.
            continue;
        }
        if (std.mem.startsWith(u8, line, "      steps:")) {
            // Enter the steps list; flush any prior step.
            continue;
        }
        if (std.mem.startsWith(u8, line, "      metadata: {}")) {
            in_metadata = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "      metadata:")) {
            in_metadata = true;
            continue;
        }
        if (in_metadata) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            try metadata.append(allocator, .{ .key = trimQuotes(key), .value = trimQuotes(value) });
            continue;
        }
        if (startsWithSpaces(line, 10) and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "- ")) {
            // A new part within the current step. The dash line itself
            // carries the `type` field.
            if (step_parts.items.len > 0) {
                if (!first_part) try out.writeAll(" ; ");
                first_part = false;
                try writePart(&out, step_parts.items);
                step_parts.clearRetainingCapacity();
            }
            const rest = std.mem.trimStart(u8, line, " ")[2..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const field = std.mem.trim(u8, rest[0..colon], " ");
            const value = std.mem.trim(u8, rest[colon + 1 ..], " \t");
            if (std.mem.eql(u8, field, "type")) {
                try step_parts.append(allocator, .{ .field = field, .value = trimQuotes(value) });
            }
            continue;
        }
        if (startsWithSpaces(line, 12)) {
            const rest = line[12..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const field = std.mem.trim(u8, rest[0..colon], " ");
            const value = std.mem.trim(u8, rest[colon + 1 ..], " \t");
            if (std.mem.eql(u8, field, "type") or std.mem.eql(u8, field, "name") or
                std.mem.eql(u8, field, "quantity") or std.mem.eql(u8, field, "units") or
                std.mem.eql(u8, field, "value"))
            {
                try step_parts.append(allocator, .{ .field = field, .value = trimQuotes(value) });
            }
            continue;
        }
        if (startsWithSpaces(line, 8) and std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), "        -")) {
            // A new step begins: flush the current one.
            if (step_parts.items.len > 0) {
                if (!first_part) try out.writeAll(" ; ");
                first_part = false;
                try writePart(&out, step_parts.items);
                step_parts.clearRetainingCapacity();
            }
            if (!first_step) try out.writeAll(" / ");
            first_step = false;
            first_part = true;
            continue;
        }
    }
    // Flush the final step's last part.
    if (step_parts.items.len > 0) {
        if (!first_part) try out.writeAll(" ; ");
        first_part = false;
        try writePart(&out, step_parts.items);
    }

    try out.writeAll(" // ");
    std.mem.sort(KeyValue, metadata.items, {}, lessThan);
    for (metadata.items, 0..) |kv, idx| {
        if (idx > 0) try out.writeAll("\n");
        try out.print("{s}={s}", .{ kv.key, kv.value });
    }
    step_parts.deinit(allocator);
    metadata.deinit(allocator);
    return out.done();
}

const PartFields = struct { field: []const u8, value: []const u8 };

fn startsWithSpaces(line: []const u8, n: usize) bool {
    return line.len >= n and isAllSpaces(line[0..n]);
}

/// Writes one canonical part from its YAML fields.
fn writePart(w: *Buf, fields: []const PartFields) !void {
    var ftype: []const u8 = "";
    var fname: []const u8 = "";
    var fquantity: []const u8 = "";
    var funits: []const u8 = "";
    var fvalue: []const u8 = "";
    for (fields) |f| {
        if (std.mem.eql(u8, f.field, "type")) ftype = f.value;
        if (std.mem.eql(u8, f.field, "name")) fname = f.value;
        if (std.mem.eql(u8, f.field, "quantity")) fquantity = f.value;
        if (std.mem.eql(u8, f.field, "units")) funits = f.value;
        if (std.mem.eql(u8, f.field, "value")) fvalue = f.value;
    }
    if (std.mem.eql(u8, ftype, "text")) {
        try w.print("T:{s}", .{fvalue});
    } else if (std.mem.eql(u8, ftype, "ingredient")) {
        try w.print("I:{s}|{s}|{s}", .{ fname, fquantity, funits });
    } else if (std.mem.eql(u8, ftype, "cookware")) {
        try w.print("C:{s}|{s}|{s}", .{ fname, fquantity, funits });
    } else if (std.mem.eql(u8, ftype, "timer")) {
        try w.print("M:{s}|{s}|{s}", .{ fquantity, funits, fname });
    } else {
        try w.print("?{s}", .{ftype});
    }
}
