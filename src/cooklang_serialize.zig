//! Canonical Cooklang serializer.
//!
//! Turns a parsed `Recipe` back into valid `.cook` text — deterministically
//! and semantically: `serialize(parse(input))` is a fixed point
//! (re-parsing the output yields the same semantic model), and
//! serializing twice yields identical bytes. This is **canonical
//! serialization, not byte-identical round-tripping**: the source's exact
//! spelling (marker style, whitespace, braces, `== Name ==` vs `= Name`,
//! comment placement) is normalized away by parsing, so the output is
//! one deterministic valid spelling of the same recipe — not the original
//! text (docs/COOKLANG.md §10).
//!
//! Canonical rules:
//!
//! - Blocks render in order, separated by one blank line; the recipe ends
//!   with a single `\n`. Front matter renders first as
//!   `---\n` + raw payload + `---\n` (the payload is passed through —
//!   it is data, not parsed — modulo the NUL → U+FFFD output policy
//!   below).
//! - A step renders its parts in order: text verbatim (text values are
//!   already join-normalized by the parser, so a multi-line step without
//!   forced breaks normally collapses to one line), tokens in canonical form, and
//!   a `line_break` part as `\` + `\n`.
//! - Tokens: `@name`, `#name`, `~name`; braces are emitted exactly when
//!   the model says the token carried them (`quantity != null` — the
//!   empty-braces form `@x{}` is `quantity = ""`, distinct from no
//!   braces at all), with `%units` when units are non-empty; the
//!   shorthand `(preparation)` follows the closing brace verbatim.
//!   Recipe references need no special form: `is_recipe_reference` is a
//!   derived flag from the name shape, and the name renders as-is.
//! - A note renders as `>` plus the note text; a section as `= ` plus
//!   its title, then its blocks.
//!
//! Step normalization is checked by reparsing before emission. If joining
//! lines or removing comments would activate literal syntax, the original
//! step's lexical boundaries are retained, with tokens still written in
//! canonical form. This preserves line-local fallback without inventing
//! an escape syntax or changing Cooklang token recognition.
//!
//! Output policy: the parser keeps NUL bytes opaque in payloads, so every
//! payload write goes through `cooklang.writeTextSanitized` — NUL (U+0000)
//! becomes U+FFFD, the same replacement the HTML renderers apply (issue
//! #56). No `0x00` byte ever reaches the emitted `.cook` text.
//!
//! The serializer has no filesystem/network/global-state dependencies,
//! like the rest of the core. See docs/COOKLANG.md §10 for the policy
//! and the canonical-vs-roundtrip distinction.

const std = @import("std");
const cooklang = @import("cooklang.zig");

const WriteError = cooklang.ParseError || error{ WriteFailed, UnrepresentableStep };

pub const SerializeOptions = struct {};

/// Writes the canonical Cooklang text for `recipe` to `writer`.
/// `gpa` owns temporary step buffers and safety-check parses. Unsafe
/// normalization requires valid source spans, as supplied by the parser
/// (and preserved by scaling); otherwise returns `UnrepresentableStep`.
pub fn serialize(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, options: SerializeOptions) !void {
    _ = options;

    if (recipe.frontmatter) |fm| {
        try writer.writeAll("---\n");
        try cooklang.writeTextSanitized(writer, fm.raw);
        try writer.writeAll("---\n");
    }
    try writeBlocks(gpa, writer, recipe, recipe.blocks, recipe.frontmatter != null);
}

fn writeBlocks(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, blocks: []const cooklang.Block, lead_blank: bool) WriteError!void {
    var first = !lead_blank;
    for (blocks) |block| {
        if (!first) try writer.writeAll("\n");
        first = false;
        try writeBlock(gpa, writer, recipe, block);
    }
}

fn writeBlock(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, block: cooklang.Block) WriteError!void {
    switch (block) {
        .step => |step| {
            try writeStep(gpa, writer, recipe, step);
        },
        .note => |note| {
            try writer.writeAll(">");
            if (note.text.len > 0) {
                try writer.writeAll(" ");
                try cooklang.writeTextSanitized(writer, note.text);
            }
            try writer.writeAll("\n");
        },
        .section => |section| {
            try writer.writeAll("= ");
            try cooklang.writeTextSanitized(writer, section.name);
            try writer.writeAll("\n");
            try writeBlocks(gpa, writer, recipe, section.blocks, true);
        },
    }
}

fn writeStep(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, step: cooklang.Step) WriteError!void {
    var canonical = std.Io.Writer.Allocating.init(gpa);
    defer canonical.deinit();
    for (step.parts) |part| try writePart(&canonical.writer, part);
    try canonical.writer.writeAll("\n");
    if (try stepMatches(gpa, canonical.written(), step)) {
        try cooklang.writeTextSanitized(writer, canonical.written());
        return;
    }

    // Only unsafe steps retain source spelling. Replace typed tokens in
    // place, so scaled quantities and canonical token forms still apply.
    // No CST or additional model fields are needed.
    const bytes = recipe.source.bytes;
    if (step.span.start > step.span.end or step.span.end > bytes.len) return error.UnrepresentableStep;
    var lexical = std.Io.Writer.Allocating.init(gpa);
    defer lexical.deinit();
    var cursor: usize = step.span.start;
    for (step.parts) |part| {
        const span = switch (part) {
            .ingredient => |t| t.span,
            .cookware => |t| t.span,
            .timer => |t| t.span,
            .text, .line_break => continue,
        };
        if (span.start < cursor or span.start > span.end or span.end > step.span.end) return error.UnrepresentableStep;
        try lexical.writer.writeAll(bytes[cursor..span.start]);
        try writePart(&lexical.writer, part);
        cursor = span.end;
    }
    try lexical.writer.writeAll(bytes[cursor..step.span.end]);
    try lexical.writer.writeAll("\n");
    if (!try stepMatches(gpa, lexical.written(), step)) return error.UnrepresentableStep;
    try cooklang.writeTextSanitized(writer, lexical.written());
}

fn stepMatches(gpa: std.mem.Allocator, text: []const u8, step: cooklang.Step) cooklang.ParseError!bool {
    // A step is body content, not a new file: fence-looking lines must
    // not be mistaken for frontmatter by this isolated safety check.
    const body = try std.mem.concat(gpa, u8, &.{ "= \n", text });
    defer gpa.free(body);
    var check = try cooklang.parse(gpa, body, .{});
    defer check.deinit();
    if (check.recipe.blocks.len != 1 or check.recipe.blocks[0] != .section) return false;
    const blocks = check.recipe.blocks[0].section.blocks;
    return blocks.len == 1 and blocks[0] == .step and stepsEqual(step, blocks[0].step);
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |text| return if (b) |other| std.mem.eql(u8, text, other) else false;
    return b == null;
}

fn stepsEqual(a: cooklang.Step, b: cooklang.Step) bool {
    if (a.parts.len != b.parts.len) return false;
    for (a.parts, b.parts) |pa, pb| {
        if (std.meta.activeTag(pa) != std.meta.activeTag(pb)) return false;
        const equal = switch (pa) {
            .text => |t| std.mem.eql(u8, t.text, pb.text.text),
            .line_break => true,
            .ingredient => |t| std.mem.eql(u8, t.name, pb.ingredient.name) and
                optionalTextEqual(t.quantity, pb.ingredient.quantity) and
                optionalTextEqual(t.units, pb.ingredient.units) and
                optionalTextEqual(t.preparation, pb.ingredient.preparation) and
                t.is_recipe_reference == pb.ingredient.is_recipe_reference,
            .cookware => |t| std.mem.eql(u8, t.name, pb.cookware.name) and
                optionalTextEqual(t.quantity, pb.cookware.quantity),
            .timer => |t| std.mem.eql(u8, t.name, pb.timer.name) and
                optionalTextEqual(t.quantity, pb.timer.quantity) and
                optionalTextEqual(t.units, pb.timer.units),
        };
        if (!equal) return false;
    }
    return true;
}

fn writePart(writer: anytype, part: cooklang.Part) !void {
    switch (part) {
        .text => |t| try writer.writeAll(t.text),
        .line_break => try writer.writeAll("\\\n"),
        .ingredient => |ig| {
            try writer.writeAll("@");
            try writer.writeAll(ig.name);
            try writeQuantity(writer, ig.quantity, ig.units);
            if (ig.preparation) |prep| {
                try writer.writeAll("(");
                try writer.writeAll(prep);
                try writer.writeAll(")");
            }
        },
        .cookware => |cw| {
            try writer.writeAll("#");
            try writer.writeAll(cw.name);
            try writeQuantity(writer, cw.quantity, null);
        },
        .timer => |tm| {
            try writer.writeAll("~");
            try writer.writeAll(tm.name);
            try writeQuantity(writer, tm.quantity, tm.units);
        },
    }
}

/// Writes `{quantity%units}` for a token that carried braces
/// (`quantity != null`); the empty-braces form is `{}`. `units` may be
/// null (cookware) or an empty string; both mean no `%` segment.
fn writeQuantity(writer: anytype, quantity: ?[]const u8, units: ?[]const u8) !void {
    const q = quantity orelse return;
    try writer.writeAll("{");
    try writer.writeAll(q);
    if (units) |u| {
        if (u.len > 0) {
            try writer.writeAll("%");
            try writer.writeAll(u);
        }
    }
    try writer.writeAll("}");
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

/// Serializes `input` to an owned buffer.
fn serializeT(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try cooklang.parse(allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try serialize(allocator, &aw.writer, &result.recipe, .{});
    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

/// Semantic equality between two recipes, ignoring source spans (the
/// round-trip contract: re-parsing canonical output yields the same
/// model). Spans are intentionally not compared — they are positions in
/// the (different) source texts.
fn expectSemanticEqual(a: *const cooklang.Recipe, b: *const cooklang.Recipe) !void {
    // Front matter: raw payloads must match byte-for-byte.
    if (a.frontmatter) |fa| {
        const fb = b.frontmatter orelse return error.FrontmatterMismatch;
        try std.testing.expectEqualStrings(fa.raw, fb.raw);
    } else if (b.frontmatter != null) {
        return error.FrontmatterMismatch;
    }
    try std.testing.expectEqual(a.blocks.len, b.blocks.len);
    for (a.blocks, b.blocks) |ba, bb| try expectBlockEqual(ba, bb);
}

fn expectBlockEqual(a: cooklang.Block, b: cooklang.Block) !void {
    switch (a) {
        .step => |sa| switch (b) {
            .step => |sb| {
                try std.testing.expectEqual(sa.parts.len, sb.parts.len);
                for (sa.parts, sb.parts) |pa, pb| try expectPartEqual(pa, pb);
                try std.testing.expect(stepsEqual(sa, sb));
            },
            else => return error.BlockMismatch,
        },
        .note => |na| switch (b) {
            .note => |nb| try std.testing.expectEqualStrings(na.text, nb.text),
            else => return error.BlockMismatch,
        },
        .section => |sa| switch (b) {
            .section => |sb| {
                try std.testing.expectEqualStrings(sa.name, sb.name);
                try std.testing.expectEqual(sa.blocks.len, sb.blocks.len);
                for (sa.blocks, sb.blocks) |ba, bb| try expectBlockEqual(ba, bb);
            },
            else => return error.BlockMismatch,
        },
    }
}

fn expectPartEqual(a: cooklang.Part, b: cooklang.Part) !void {
    switch (a) {
        .text => |ta| switch (b) {
            .text => |tb| try std.testing.expectEqualStrings(ta.text, tb.text),
            else => return error.PartMismatch,
        },
        .line_break => switch (b) {
            .line_break => {},
            else => return error.PartMismatch,
        },
        .ingredient => |ia| switch (b) {
            .ingredient => |ib| {
                try std.testing.expectEqualStrings(ia.name, ib.name);
                try std.testing.expectEqualStrings(ia.quantity orelse "", ib.quantity orelse "");
                try std.testing.expectEqualStrings(ia.units orelse "", ib.units orelse "");
                try std.testing.expectEqual(ia.is_recipe_reference, ib.is_recipe_reference);
                try std.testing.expectEqualStrings(ia.preparation orelse "", ib.preparation orelse "");
            },
            else => return error.PartMismatch,
        },
        .cookware => |ca| switch (b) {
            .cookware => |cb| {
                try std.testing.expectEqualStrings(ca.name, cb.name);
                try std.testing.expectEqualStrings(ca.quantity orelse "", cb.quantity orelse "");
            },
            else => return error.PartMismatch,
        },
        .timer => |ta| switch (b) {
            .timer => |tb| {
                try std.testing.expectEqualStrings(ta.name, tb.name);
                try std.testing.expectEqualStrings(ta.quantity orelse "", tb.quantity orelse "");
                try std.testing.expectEqualStrings(ta.units orelse "", tb.units orelse "");
            },
            else => return error.PartMismatch,
        },
    }
}

// The round-trip contract: parse -> serialize -> parse must yield the
// same semantic model as the first parse, and serializing the canonical
// output again must be byte-identical (a fixed point).
test "cooklang serialize: canonical output is a semantic round-trip fixed point" {
    const cases = [_][]const u8{
        "",
        "Add @salt.",
        "Mix @flour{200%g} and @water{100%ml}.",
        "Add @salt, @ground black pepper{} and @potato{2}.",
        "Fry in #frying pan{2} for ~{25%minutes}, then ~rest and ~eggs{3%minutes}.",
        "Pour over with @./sauces/Hollandaise{150%g}.",
        "Mix @onion{1}(peeled and finely chopped) and @garlic{2%cloves}(peeled and minced).",
        "Mash @potato{2%kg} until smooth -- alternatively boil 'em",
        "Slowly add @milk{4%cup} [- TODO -], keep mixing",
        "Lay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).",
        "> Don't burn the roux!",
        "= Dough\n\nMix @flour{200%g} and @water{100%ml} together until smooth.\n\n== Filling ==\nCombine @cheese{100%g}(grated) and @spinach{50%g}.",
        "---\ntitle: Pasta\nservings: 2\n---\n\nBoil @pasta{200%g} in salted water.",
        "---\n---\n\nEmpty front matter.",
        "Add @salt and @pepper{1%tsp} and @1000 island dressing{ }.",
        "Keep @red-chilli and @salt and keep @🧂 intact.",
        "Message @ example{} and @{3} and ~ 5 stay literal.",
        "@abc\xFFdef{1} with malformed bytes.",
    };
    for (cases) |input| {
        const once = try serializeT(std.testing.allocator, input);
        defer std.testing.allocator.free(once);

        // Fixed point: serializing the canonical output again is stable.
        const twice = try serializeT(std.testing.allocator, once);
        defer std.testing.allocator.free(twice);
        try std.testing.expectEqualStrings(once, twice);

        // Semantic round trip: the first parse and the canonical re-parse
        // yield the same model (spans ignored).
        var r1 = try cooklang.parse(std.testing.allocator, input, .{});
        defer r1.deinit();
        var r2 = try cooklang.parse(std.testing.allocator, once, .{});
        defer r2.deinit();
        try expectSemanticEqual(&r1.recipe, &r2.recipe);
    }
}

test "cooklang serialize: canonical spellings" {
    const a = try serializeT(std.testing.allocator, "Add @salt, @ground black pepper{} and @potato{2}.");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("Add @salt, @ground black pepper{} and @potato{2}.\n", a);

    // The empty-braces form is preserved (quantity "" vs no braces).
    const b = try serializeT(std.testing.allocator, "@x{}");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("@x{}\n", b);

    // `== Name ==` normalizes to `= Name`; breaks and notes keep shape.
    const c = try serializeT(std.testing.allocator, "== Filling ==\n\n> A note.\n\nLay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("= Filling\n\n> A note.\n\nLay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).\n", c);

    // Front matter passes through verbatim with a canonical fence pair.
    const d = try serializeT(std.testing.allocator, "---\ntitle: Pasta\n---\n\nBoil @pasta{200%g}.");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("---\ntitle: Pasta\n---\n\nBoil @pasta{200%g}.\n", d);

    // Empty input serializes to nothing.
    const e = try serializeT(std.testing.allocator, "");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("", e);
}

test "cooklang serialize: block comment at line end joins cleanly (issue #159)" {
    // The comment is stripped and the step collapses to joined text —
    // the close-at-line-end case used to leak a raw newline into the
    // text value and fall back to the lexical (verbatim) path.
    const out = try serializeT(std.testing.allocator, "x [- a\n-]\ny\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("x  y\n", out);
    // Round-trips: re-serializing the canonical output is stable.
    const twice = try serializeT(std.testing.allocator, out);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(out, twice);
}

test "cooklang serialize: non-ingredient preparations and units stay literal (issue #167)" {
    // `(soft)`/`(big)` are trailing text and `1%large` is the cookware
    // quantity text — every source byte survives serialization.
    const input = "Fry ~eggs{3%minutes}(soft) in #pan{2}(big) with #lid{1%large}\n";
    const out = try serializeT(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "cooklang serialize: NUL bytes emit U+FFFD, never raw 0x00 (issue #161)" {
    // Same policy as the HTML renderers (issue #56): the parser keeps
    // NUL opaque, so text output replaces it — a raw 0x00 is a corrupt
    // file for editors, diff, and TSV tooling.
    const input = "text\x00more\n\n= Se\x00ction\n\n> no\x00te\n\n@sa\x00lt{1\x00} in #pa\x00n{2} for ~e\x00ggs{3%min\x00utes}\n";
    const out = try serializeT(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0) == null);
    try std.testing.expectEqualStrings(
        "text\u{FFFD}more\n\n= Se\u{FFFD}ction\n\n> no\u{FFFD}te\n\n@sa\u{FFFD}lt{1\u{FFFD}} in #pa\u{FFFD}n{2} for ~e\u{FFFD}ggs{3%min\u{FFFD}utes}\n",
        out,
    );
    // Front matter payload gets the same treatment.
    const fm = try serializeT(std.testing.allocator, "---\nx\x00y: z\n---\n\nAdd @salt.\n");
    defer std.testing.allocator.free(fm);
    try std.testing.expect(std.mem.indexOfScalar(u8, fm, 0) == null);
}

fn expectRoundTrip(input: []const u8) !void {
    const once = try serializeT(std.testing.allocator, input);
    defer std.testing.allocator.free(once);
    const twice = try serializeT(std.testing.allocator, once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
    var original = try cooklang.parse(std.testing.allocator, input, .{});
    defer original.deinit();
    var reparsed = try cooklang.parse(std.testing.allocator, once, .{});
    defer reparsed.deinit();
    try expectSemanticEqual(&original.recipe, &reparsed.recipe);
}

test "cooklang serialize: line-split literal tokens retain their boundaries (#134)" {
    const cases = [_][]const u8{
        "@x{\n}",
        "#pan{\n}",
        "~{\n}",
        "@flour{1\n2%g}",
        "#pan{1\n2}",
        "~rest{1\n2%minutes}",
        "@flour{12%\ng}",
        "~{12%min\nutes}",
        "@flour{12%g\n}",
        "@ground\npepper{}",
        "#frying\npan{}",
        "~boil\neggs{12%minutes}",
        "@x{}(sliced\nfinely)",
        "Mix @salt\npepper{1%g}.",
        "@[- removed -]x{}",
        "@x{[- removed -]\n}",
        "x [-\n\n= hidden\n> @hidden{}\n-] y",
        "= Section\n\n@x{\n}",
        "= Section\n\n---\n@x{\n}\n---",
        "First step.\n\n---\n@x{\n}\n---",
        "---\ntitle: Test\n---\n\n@x{\n}",
    };
    for (cases) |input| try expectRoundTrip(input);
    const canonical = try serializeT(std.testing.allocator, "@x{\n}");
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("@x{\n}\n", canonical);

    // The token remains literal, with the same intentional warning.
    var original = try cooklang.parse(std.testing.allocator, "@x{\n}", .{});
    defer original.deinit();
    var reparsed = try cooklang.parse(std.testing.allocator, canonical, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("@x{ }", original.recipe.blocks[0].step.parts[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), original.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), reparsed.diagnostics.len);
    try std.testing.expectEqualStrings("unclosed-braces", original.diagnostics[0].code);
    try std.testing.expectEqual(original.diagnostics[0].span, reparsed.diagnostics[0].span);
}

test "cooklang serialize: every component split and line ending is a fixed point" {
    // Ingredient/cookware/named and unnamed timer forms, with a split
    // at every byte in the name, quantity, units, and closing delimiter.
    for ([_][]const u8{
        "@ground pepper{12%grams}",
        "#frying pan{12}",
        "~boil eggs{12%minutes}",
        "~{12%minutes}",
        "@x{1}(sliced finely)",
    }) |token| {
        for ([_][]const u8{ "\n", "\r\n", "\r" }) |ending| {
            for (1..token.len) |split| {
                const input = try std.mem.concat(std.testing.allocator, u8, &.{ token[0..split], ending, token[split..] });
                defer std.testing.allocator.free(input);
                try expectRoundTrip(input);
            }
        }
    }
}

test "cooklang serialize: unsafe steps still serialize scaled tokens canonically" {
    const scale = @import("cooklang_scale.zig");
    var original = try cooklang.parse(std.testing.allocator, "@rice{2%cup} with @x{\n}", .{});
    defer original.deinit();
    var scaled = try scale.scaleRecipe(std.testing.allocator, &original.recipe, .{ .factor = .{ .num = 2, .den = 1 } });
    defer scaled.deinit();
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try serialize(std.testing.allocator, &writer.writer, &scaled, .{});
    try std.testing.expectEqualStrings("@rice{4%cup} with @x{\n}\n", writer.written());
    var reparsed = try cooklang.parse(std.testing.allocator, writer.written(), .{});
    defer reparsed.deinit();
    try expectSemanticEqual(&scaled, &reparsed.recipe);
    try expectRoundTrip(writer.written());
}

test "cooklang serialize: unsafe normalization rejects missing or inconsistent source spans" {
    var original = try cooklang.parse(std.testing.allocator, "@x{\n}", .{});
    defer original.deinit();
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    original.recipe.source.bytes = "";
    try std.testing.expectError(error.UnrepresentableStep, serialize(std.testing.allocator, &writer.writer, &original.recipe, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    original.recipe.source.bytes = "abcde";
    try std.testing.expectError(error.UnrepresentableStep, serialize(std.testing.allocator, &writer.writer, &original.recipe, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
}
