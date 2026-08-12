//! Fixture-driven tests.
//!
//! Convention (see docs/TESTS.md): for each fixture `<name>` there is an
//! input file `tests/fixtures/<dialect>/<name>.<ext>` (`.md` for markdown,
//! `.textile` for textile) and an expected-output file
//! `tests/fixtures/<dialect>/<name>.html`. Expected outputs are exact bytes:
//! trailing newlines matter. Fixtures are embedded at comptime so tests run
//! anywhere without filesystem access; the list below is the index.
//!
//! Markdown and Textile fixtures live in separate directories even when they
//! describe the same normalized structure.

const std = @import("std");
const oliver = @import("oliver");

const MarkdownFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const markdown_fixtures = [_]MarkdownFixture{
    .{
        .name = "paragraph",
        .input = @embedFile("fixtures/markdown/paragraph.md"),
        .expected = @embedFile("fixtures/markdown/paragraph.html"),
    },
    .{
        .name = "two-paragraphs",
        .input = @embedFile("fixtures/markdown/two-paragraphs.md"),
        .expected = @embedFile("fixtures/markdown/two-paragraphs.html"),
    },
    .{
        .name = "paragraph-soft-break",
        .input = @embedFile("fixtures/markdown/paragraph-soft-break.md"),
        .expected = @embedFile("fixtures/markdown/paragraph-soft-break.html"),
    },
    .{
        .name = "blank-lines",
        .input = @embedFile("fixtures/markdown/blank-lines.md"),
        .expected = @embedFile("fixtures/markdown/blank-lines.html"),
    },
    .{
        .name = "heading-atx",
        .input = @embedFile("fixtures/markdown/heading-atx.md"),
        .expected = @embedFile("fixtures/markdown/heading-atx.html"),
    },
    .{
        .name = "heading-closing",
        .input = @embedFile("fixtures/markdown/heading-closing.md"),
        .expected = @embedFile("fixtures/markdown/heading-closing.html"),
    },
    .{
        .name = "heading-empty",
        .input = @embedFile("fixtures/markdown/heading-empty.md"),
        .expected = @embedFile("fixtures/markdown/heading-empty.html"),
    },
    .{
        .name = "heading-not",
        .input = @embedFile("fixtures/markdown/heading-not.md"),
        .expected = @embedFile("fixtures/markdown/heading-not.html"),
    },
    .{
        .name = "heading-interrupts",
        .input = @embedFile("fixtures/markdown/heading-interrupts.md"),
        .expected = @embedFile("fixtures/markdown/heading-interrupts.html"),
    },
    .{
        .name = "heading-escaped-closing",
        .input = @embedFile("fixtures/markdown/heading-escaped-closing.md"),
        .expected = @embedFile("fixtures/markdown/heading-escaped-closing.html"),
    },
    .{
        .name = "escape-paragraph",
        .input = @embedFile("fixtures/markdown/escape-paragraph.md"),
        .expected = @embedFile("fixtures/markdown/escape-paragraph.html"),
    },
    .{
        .name = "escapes",
        .input = @embedFile("fixtures/markdown/escapes.md"),
        .expected = @embedFile("fixtures/markdown/escapes.html"),
    },
    .{
        .name = "escape-nonpunct",
        .input = @embedFile("fixtures/markdown/escape-nonpunct.md"),
        .expected = @embedFile("fixtures/markdown/escape-nonpunct.html"),
    },
    .{
        .name = "escape-escaped-backslash",
        .input = @embedFile("fixtures/markdown/escape-escaped-backslash.md"),
        .expected = @embedFile("fixtures/markdown/escape-escaped-backslash.html"),
    },
    .{
        .name = "hard-break-spaces",
        .input = @embedFile("fixtures/markdown/hard-break-spaces.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-spaces.html"),
    },
    .{
        .name = "hard-break-backslash",
        .input = @embedFile("fixtures/markdown/hard-break-backslash.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-backslash.html"),
    },
    .{
        .name = "soft-break-single-space",
        .input = @embedFile("fixtures/markdown/soft-break-single-space.md"),
        .expected = @embedFile("fixtures/markdown/soft-break-single-space.html"),
    },
    .{
        .name = "hard-break-last-line",
        .input = @embedFile("fixtures/markdown/hard-break-last-line.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-last-line.html"),
    },
    .{
        .name = "indent-continuation",
        .input = @embedFile("fixtures/markdown/indent-continuation.md"),
        .expected = @embedFile("fixtures/markdown/indent-continuation.html"),
    },
    .{
        .name = "indent-heading",
        .input = @embedFile("fixtures/markdown/indent-heading.md"),
        .expected = @embedFile("fixtures/markdown/indent-heading.html"),
    },
    .{
        .name = "escape-special",
        .input = @embedFile("fixtures/markdown/escape-special.md"),
        .expected = @embedFile("fixtures/markdown/escape-special.html"),
    },
    .{
        .name = "unicode",
        .input = @embedFile("fixtures/markdown/unicode.md"),
        .expected = @embedFile("fixtures/markdown/unicode.html"),
    },
    // --- emphasis / strong emphasis (docs/INLINE-PARSING.md §15) ---
    .{
        .name = "em-simple",
        .input = @embedFile("fixtures/markdown/em-simple.md"),
        .expected = @embedFile("fixtures/markdown/em-simple.html"),
    },
    .{
        .name = "strong-simple",
        .input = @embedFile("fixtures/markdown/strong-simple.md"),
        .expected = @embedFile("fixtures/markdown/strong-simple.html"),
    },
    .{
        .name = "em-underscore",
        .input = @embedFile("fixtures/markdown/em-underscore.md"),
        .expected = @embedFile("fixtures/markdown/em-underscore.html"),
    },
    .{
        .name = "strong-underscore",
        .input = @embedFile("fixtures/markdown/strong-underscore.md"),
        .expected = @embedFile("fixtures/markdown/strong-underscore.html"),
    },
    .{
        .name = "em-nested-strong",
        .input = @embedFile("fixtures/markdown/em-nested-strong.md"),
        .expected = @embedFile("fixtures/markdown/em-nested-strong.html"),
    },
    .{
        .name = "em-intraword",
        .input = @embedFile("fixtures/markdown/em-intraword.md"),
        .expected = @embedFile("fixtures/markdown/em-intraword.html"),
    },
    .{
        .name = "underscore-intraword",
        .input = @embedFile("fixtures/markdown/underscore-intraword.md"),
        .expected = @embedFile("fixtures/markdown/underscore-intraword.html"),
    },
    .{
        .name = "em-malformed-space",
        .input = @embedFile("fixtures/markdown/em-malformed-space.md"),
        .expected = @embedFile("fixtures/markdown/em-malformed-space.html"),
    },
    .{
        .name = "em-mod3",
        .input = @embedFile("fixtures/markdown/em-mod3.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3.html"),
    },
    .{
        .name = "em-mod3-2",
        .input = @embedFile("fixtures/markdown/em-mod3-2.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3-2.html"),
    },
    .{
        .name = "strong-intraword",
        .input = @embedFile("fixtures/markdown/strong-intraword.md"),
        .expected = @embedFile("fixtures/markdown/strong-intraword.html"),
    },
    .{
        .name = "strong-mod3",
        .input = @embedFile("fixtures/markdown/strong-mod3.md"),
        .expected = @embedFile("fixtures/markdown/strong-mod3.html"),
    },
    .{
        .name = "em-mod3-hello",
        .input = @embedFile("fixtures/markdown/em-mod3-hello.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3-hello.html"),
    },
    .{
        .name = "em-literal",
        .input = @embedFile("fixtures/markdown/em-literal.md"),
        .expected = @embedFile("fixtures/markdown/em-literal.html"),
    },
    .{
        .name = "em-escapes",
        .input = @embedFile("fixtures/markdown/em-escapes.md"),
        .expected = @embedFile("fixtures/markdown/em-escapes.html"),
    },
    .{
        .name = "em-breaks",
        .input = @embedFile("fixtures/markdown/em-breaks.md"),
        .expected = @embedFile("fixtures/markdown/em-breaks.html"),
    },
    .{
        .name = "em-heading",
        .input = @embedFile("fixtures/markdown/em-heading.md"),
        .expected = @embedFile("fixtures/markdown/em-heading.html"),
    },
    .{
        .name = "em-unicode",
        .input = @embedFile("fixtures/markdown/em-unicode.md"),
        .expected = @embedFile("fixtures/markdown/em-unicode.html"),
    },
    .{
        .name = "code-simple",
        .input = @embedFile("fixtures/markdown/code-simple.md"),
        .expected = @embedFile("fixtures/markdown/code-simple.html"),
    },
    .{
        .name = "code-empty",
        .input = @embedFile("fixtures/markdown/code-empty.md"),
        .expected = @embedFile("fixtures/markdown/code-empty.html"),
    },
    .{
        .name = "code-run-length",
        .input = @embedFile("fixtures/markdown/code-run-length.md"),
        .expected = @embedFile("fixtures/markdown/code-run-length.html"),
    },
    .{
        .name = "code-trim",
        .input = @embedFile("fixtures/markdown/code-trim.md"),
        .expected = @embedFile("fixtures/markdown/code-trim.html"),
    },
    .{
        .name = "code-multiline",
        .input = @embedFile("fixtures/markdown/code-multiline.md"),
        .expected = @embedFile("fixtures/markdown/code-multiline.html"),
    },
    .{
        .name = "code-escapes",
        .input = @embedFile("fixtures/markdown/code-escapes.md"),
        .expected = @embedFile("fixtures/markdown/code-escapes.html"),
    },
    .{
        .name = "code-opacity",
        .input = @embedFile("fixtures/markdown/code-opacity.md"),
        .expected = @embedFile("fixtures/markdown/code-opacity.html"),
    },
    .{
        .name = "code-emphasis",
        .input = @embedFile("fixtures/markdown/code-emphasis.md"),
        .expected = @embedFile("fixtures/markdown/code-emphasis.html"),
    },
    .{
        .name = "code-heading",
        .input = @embedFile("fixtures/markdown/code-heading.md"),
        .expected = @embedFile("fixtures/markdown/code-heading.html"),
    },
    .{
        .name = "code-unicode",
        .input = @embedFile("fixtures/markdown/code-unicode.md"),
        .expected = @embedFile("fixtures/markdown/code-unicode.html"),
    },
    .{
        .name = "code-unmatched",
        .input = @embedFile("fixtures/markdown/code-unmatched.md"),
        .expected = @embedFile("fixtures/markdown/code-unmatched.html"),
    },
    .{
        .name = "code-blocks",
        .input = @embedFile("fixtures/markdown/code-blocks.md"),
        .expected = @embedFile("fixtures/markdown/code-blocks.html"),
    },
    // --- inline links (docs/INLINE-PARSING.md §6.6) ---
    .{
        .name = "link-simple",
        .input = @embedFile("fixtures/markdown/link-simple.md"),
        .expected = @embedFile("fixtures/markdown/link-simple.html"),
    },
    .{
        .name = "link-no-title",
        .input = @embedFile("fixtures/markdown/link-no-title.md"),
        .expected = @embedFile("fixtures/markdown/link-no-title.html"),
    },
    .{
        .name = "link-empty",
        .input = @embedFile("fixtures/markdown/link-empty.md"),
        .expected = @embedFile("fixtures/markdown/link-empty.html"),
    },
    .{
        .name = "link-angle-space",
        .input = @embedFile("fixtures/markdown/link-angle-space.md"),
        .expected = @embedFile("fixtures/markdown/link-angle-space.html"),
    },
    .{
        .name = "link-dest-escaped-parens",
        .input = @embedFile("fixtures/markdown/link-dest-escaped-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-dest-escaped-parens.html"),
    },
    .{
        .name = "link-dest-escaped-symbols",
        .input = @embedFile("fixtures/markdown/link-dest-escaped-symbols.md"),
        .expected = @embedFile("fixtures/markdown/link-dest-escaped-symbols.html"),
    },
    .{
        .name = "link-balanced-parens",
        .input = @embedFile("fixtures/markdown/link-balanced-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-balanced-parens.html"),
    },
    .{
        .name = "link-unbalanced-parens",
        .input = @embedFile("fixtures/markdown/link-unbalanced-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-unbalanced-parens.html"),
    },
    .{
        .name = "link-bare-backslash",
        .input = @embedFile("fixtures/markdown/link-bare-backslash.md"),
        .expected = @embedFile("fixtures/markdown/link-bare-backslash.html"),
    },
    .{
        .name = "link-titles",
        .input = @embedFile("fixtures/markdown/link-titles.md"),
        .expected = @embedFile("fixtures/markdown/link-titles.html"),
    },
    .{
        .name = "link-nested-brackets",
        .input = @embedFile("fixtures/markdown/link-nested-brackets.md"),
        .expected = @embedFile("fixtures/markdown/link-nested-brackets.html"),
    },
    .{
        .name = "link-inline-content",
        .input = @embedFile("fixtures/markdown/link-inline-content.md"),
        .expected = @embedFile("fixtures/markdown/link-inline-content.html"),
    },
    .{
        .name = "link-no-nesting",
        .input = @embedFile("fixtures/markdown/link-no-nesting.md"),
        .expected = @embedFile("fixtures/markdown/link-no-nesting.html"),
    },
    .{
        .name = "link-precedence",
        .input = @embedFile("fixtures/markdown/link-precedence.md"),
        .expected = @embedFile("fixtures/markdown/link-precedence.html"),
    },
    .{
        .name = "link-code-span",
        .input = @embedFile("fixtures/markdown/link-code-span.md"),
        .expected = @embedFile("fixtures/markdown/link-code-span.html"),
    },
    .{
        .name = "link-escaped-bracket",
        .input = @embedFile("fixtures/markdown/link-escaped-bracket.md"),
        .expected = @embedFile("fixtures/markdown/link-escaped-bracket.html"),
    },
    .{
        .name = "link-not-a-link",
        .input = @embedFile("fixtures/markdown/link-not-a-link.md"),
        .expected = @embedFile("fixtures/markdown/link-not-a-link.html"),
    },
    .{
        .name = "link-heading",
        .input = @embedFile("fixtures/markdown/link-heading.md"),
        .expected = @embedFile("fixtures/markdown/link-heading.html"),
    },
    .{
        .name = "link-em-wrapped",
        .input = @embedFile("fixtures/markdown/link-em-wrapped.md"),
        .expected = @embedFile("fixtures/markdown/link-em-wrapped.html"),
    },
    .{
        .name = "link-quote-dest",
        .input = @embedFile("fixtures/markdown/link-quote-dest.md"),
        .expected = @embedFile("fixtures/markdown/link-quote-dest.html"),
    },
    .{
        .name = "link-multiline-title",
        .input = @embedFile("fixtures/markdown/link-multiline-title.md"),
        .expected = @embedFile("fixtures/markdown/link-multiline-title.html"),
    },
    .{
        .name = "link-entity",
        .input = @embedFile("fixtures/markdown/link-entity.md"),
        .expected = @embedFile("fixtures/markdown/link-entity.html"),
    },
    // --- inline images (docs/IMAGES-PARSING.md §7) ---
    .{
        .name = "image-simple",
        .input = @embedFile("fixtures/markdown/image-simple.md"),
        .expected = @embedFile("fixtures/markdown/image-simple.html"),
    },
    .{
        .name = "image-no-title",
        .input = @embedFile("fixtures/markdown/image-no-title.md"),
        .expected = @embedFile("fixtures/markdown/image-no-title.html"),
    },
    .{
        .name = "image-title",
        .input = @embedFile("fixtures/markdown/image-title.md"),
        .expected = @embedFile("fixtures/markdown/image-title.html"),
    },
    .{
        .name = "image-angle-dest",
        .input = @embedFile("fixtures/markdown/image-angle-dest.md"),
        .expected = @embedFile("fixtures/markdown/image-angle-dest.html"),
    },
    .{
        .name = "image-empty-alt",
        .input = @embedFile("fixtures/markdown/image-empty-alt.md"),
        .expected = @embedFile("fixtures/markdown/image-empty-alt.html"),
    },
    .{
        .name = "image-escaped",
        .input = @embedFile("fixtures/markdown/image-escaped.md"),
        .expected = @embedFile("fixtures/markdown/image-escaped.html"),
    },
    .{
        .name = "image-nested",
        .input = @embedFile("fixtures/markdown/image-nested.md"),
        .expected = @embedFile("fixtures/markdown/image-nested.html"),
    },
    .{
        .name = "image-link-inside",
        .input = @embedFile("fixtures/markdown/image-link-inside.md"),
        .expected = @embedFile("fixtures/markdown/image-link-inside.html"),
    },
    .{
        .name = "image-in-link",
        .input = @embedFile("fixtures/markdown/image-in-link.md"),
        .expected = @embedFile("fixtures/markdown/image-in-link.html"),
    },
    .{
        .name = "image-alt-flatten",
        .input = @embedFile("fixtures/markdown/image-alt-flatten.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-flatten.html"),
    },
    .{
        .name = "image-alt-code",
        .input = @embedFile("fixtures/markdown/image-alt-code.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-code.html"),
    },
    .{
        .name = "image-alt-breaks",
        .input = @embedFile("fixtures/markdown/image-alt-breaks.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-breaks.html"),
    },
    .{
        .name = "image-inactive-bracket",
        .input = @embedFile("fixtures/markdown/image-inactive-bracket.md"),
        .expected = @embedFile("fixtures/markdown/image-inactive-bracket.html"),
    },
    .{
        .name = "image-heading",
        .input = @embedFile("fixtures/markdown/image-heading.md"),
        .expected = @embedFile("fixtures/markdown/image-heading.html"),
    },
    .{
        .name = "image-emphasis",
        .input = @embedFile("fixtures/markdown/image-emphasis.md"),
        .expected = @embedFile("fixtures/markdown/image-emphasis.html"),
    },
    .{
        .name = "image-code-span",
        .input = @embedFile("fixtures/markdown/image-code-span.md"),
        .expected = @embedFile("fixtures/markdown/image-code-span.html"),
    },
    .{
        .name = "image-unclosed",
        .input = @embedFile("fixtures/markdown/image-unclosed.md"),
        .expected = @embedFile("fixtures/markdown/image-unclosed.html"),
    },
};

const TextileFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const textile_fixtures = [_]TextileFixture{
    .{
        .name = "paragraph",
        .input = @embedFile("fixtures/textile/paragraph.textile"),
        .expected = @embedFile("fixtures/textile/paragraph.html"),
    },
    .{
        .name = "two-paragraphs",
        .input = @embedFile("fixtures/textile/two-paragraphs.textile"),
        .expected = @embedFile("fixtures/textile/two-paragraphs.html"),
    },
    .{
        .name = "linebreak",
        .input = @embedFile("fixtures/textile/linebreak.textile"),
        .expected = @embedFile("fixtures/textile/linebreak.html"),
    },
    .{
        .name = "p-prefix",
        .input = @embedFile("fixtures/textile/p-prefix.textile"),
        .expected = @embedFile("fixtures/textile/p-prefix.html"),
    },
    .{
        .name = "heading",
        .input = @embedFile("fixtures/textile/heading.textile"),
        .expected = @embedFile("fixtures/textile/heading.html"),
    },
    .{
        .name = "heading-not",
        .input = @embedFile("fixtures/textile/heading-not.textile"),
        .expected = @embedFile("fixtures/textile/heading-not.html"),
    },
    .{
        .name = "mixed",
        .input = @embedFile("fixtures/textile/mixed.textile"),
        .expected = @embedFile("fixtures/textile/mixed.html"),
    },
    .{
        .name = "interrupt",
        .input = @embedFile("fixtures/textile/interrupt.textile"),
        .expected = @embedFile("fixtures/textile/interrupt.html"),
    },
    .{
        .name = "special-chars",
        .input = @embedFile("fixtures/textile/special-chars.textile"),
        .expected = @embedFile("fixtures/textile/special-chars.html"),
    },
    .{
        .name = "unicode",
        .input = @embedFile("fixtures/textile/unicode.textile"),
        .expected = @embedFile("fixtures/textile/unicode.html"),
    },
};

fn renderHtml(input: []const u8, dialect: oliver.Dialect) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, dialect, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

fn checkFixture(name: []const u8, dialect: oliver.Dialect, input: []const u8, expected: []const u8) !void {
    var out = try renderHtml(input, dialect);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

test "markdown fixtures" {
    for (markdown_fixtures) |f| {
        try checkFixture(f.name, .markdown, f.input, f.expected);
    }
}

test "textile fixtures" {
    for (textile_fixtures) |f| {
        try checkFixture(f.name, .textile, f.input, f.expected);
    }
}

test "shared model: equivalent inputs render identically through one renderer" {
    // The same normalized structure produced by either dialect must render
    // identically: this is the core convergence claim.
    const pairs = [_]struct { markdown: []const u8, textile: []const u8, expected: []const u8 }{
        .{
            .markdown = "# Hello",
            .textile = "h1. Hello",
            .expected = "<h1>Hello</h1>\n",
        },
        .{
            .markdown = "plain text",
            .textile = "plain text",
            .expected = "<p>plain text</p>\n",
        },
        .{
            .markdown = "## Two\n\nSecond.",
            .textile = "h2. Two\n\nSecond.",
            .expected = "<h2>Two</h2>\n<p>Second.</p>\n",
        },
    };
    for (pairs) |p| {
        var from_md = try renderHtml(p.markdown, .markdown);
        defer from_md.deinit(std.testing.allocator);
        var from_tx = try renderHtml(p.textile, .textile);
        defer from_tx.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(p.expected, from_md.items);
        try std.testing.expectEqualStrings(p.expected, from_tx.items);
    }
}

test "adversarial smoke: hostile input never crashes or leaks" {
    // Cheap stand-ins for fuzzing: pathological punctuation, NUL bytes,
    // mixed line endings, huge delimiter runs. The contract is no crash, no
    // hang, no unbounded recursion, deterministic output.
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    @memset(big, '#');
    const big_backslashes = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_backslashes);
    @memset(big_backslashes, '\\');

    // 100 KB of `*`: one giant delimiter run through the match/emit phases.
    const big_stars = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_stars);
    @memset(big_stars, '*');

    // Deep open chain "*a *b *c ..." — 10k unclosed opener runs on the
    // delimiter stack; completion proves matching and emission are
    // stack-safe (no recursion) and that openers_bottom keeps it linear.
    var deep_nest = std.ArrayList(u8).empty;
    defer deep_nest.deinit(gpa);
    for (0..10_000) |_| try deep_nest.appendSlice(gpa, "*a ");

    // Alternating `*`/`_` runs: every run intraword-flanks both ways; the
    // mod-3 rule and the shared bottoms table get a hostile workout.
    var alternating = std.ArrayList(u8).empty;
    defer alternating.deinit(gpa);
    for (0..50_000) |_| try alternating.appendSlice(gpa, "*_");

    // 100 KB of backticks: one giant backtick string through the discovery
    // pass (which must stay linear), plus alternated backtick/delimiter runs
    // exercising code-span opacity under stress.
    const big_backticks = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_backticks);
    @memset(big_backticks, '`');
    var backtick_mix = std.ArrayList(u8).empty;
    defer backtick_mix.deinit(gpa);
    for (0..50_000) |_| try backtick_mix.appendSlice(gpa, "`*");

    // 100 KB of `[`: one giant bracket run through link discovery (the
    // bracket stack must not blow up and the splice must stay linear),
    // plus a pathological mix of brackets/links/backticks/delimiters.
    const big_brackets = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_brackets);
    @memset(big_brackets, '[');
    var link_mix = std.ArrayList(u8).empty;
    defer link_mix.deinit(gpa);
    for (0..20_000) |_| try link_mix.appendSlice(gpa, "[a](u) *b* `c` _d_ ");
    var deep_brackets = std.ArrayList(u8).empty;
    defer deep_brackets.deinit(gpa);
    for (0..10_000) |_| try deep_brackets.appendSlice(gpa, "[x]");
    var unbalanced_links = std.ArrayList(u8).empty;
    defer unbalanced_links.deinit(gpa);
    for (0..20_000) |_| try unbalanced_links.appendSlice(gpa, "[a](");

    // Images share the link DoS guards: `![a](` repeated must not make
    // every `]` rescan the whole paragraph (same guard as the `[a](` bomb).
    var unbalanced_images = std.ArrayList(u8).empty;
    defer unbalanced_images.deinit(gpa);
    for (0..20_000) |_| try unbalanced_images.appendSlice(gpa, "![a](");

    // Deep `![` openers on the bracket stack (never closed: literal), and
    // a mixed image/link/delimiter/backtick workload.
    var deep_images = std.ArrayList(u8).empty;
    defer deep_images.deinit(gpa);
    for (0..10_000) |_| try deep_images.appendSlice(gpa, "![");
    var image_mix = std.ArrayList(u8).empty;
    defer image_mix.deinit(gpa);
    for (0..20_000) |_| try image_mix.appendSlice(gpa, "![a](u) *b* `c` ");

    // The inactive-bracket marking shape: every `]` forms a link whose
    // opener leaves a dead `[` below on the stack (the monotone check
    // keeps this linear; naive re-marking would be quadratic).
    var nested_link_marks = std.ArrayList(u8).empty;
    defer nested_link_marks.deinit(gpa);
    for (0..5_000) |_| try nested_link_marks.appendSlice(gpa, "[[a](u) ");

    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n\n",
        "#",
        "##",
        "### ###",
        "##########",
        "############################## foo ##############################",
        "#5 bolt\n#hashtag\n####### seven",
        "h1.\nh0. x\nh7. y\np.",
        "a\r\nb\rc\nd\r",
        "\x00\x00\x00",
        "a\x00b",
        "# \x00 hidden",
        "a  \nb\\\nc",
        "\\\\x",
        " \n",
        "*\n_\n\n*foo*\n_foo_",
        "*a **b ***c ****d**** e** f* g*",
        "*_*_*\n_*_*_\n",
        big,
        big_backslashes,
        big_stars,
        deep_nest.items,
        alternating.items,
        big_backticks,
        backtick_mix.items,
        big_brackets,
        link_mix.items,
        deep_brackets.items,
        unbalanced_links.items,
        unbalanced_images.items,
        deep_images.items,
        image_mix.items,
        nested_link_marks.items,
    };
    for (cases) |c| {
        inline for ([_]oliver.Dialect{ .markdown, .textile }) |dialect| {
            {
                var result = try oliver.parse(gpa, c, dialect, .{});
                defer result.deinit();
                var aw = std.Io.Writer.Allocating.init(gpa);
                defer aw.deinit();
                try oliver.html.render(gpa, &aw.writer, &result.document, .{});
            }
        }
    }
}

test "adversarial: NUL bytes render as U+FFFD" {
    var result = try oliver.parse(std.testing.allocator, "a\x00b", .markdown, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<p>a\u{FFFD}b</p>\n", out.items);
}

test "diagnostics: fixtures parse without diagnostics" {
    for (markdown_fixtures) |f| {
        var result = try oliver.parse(std.testing.allocator, f.input, .markdown, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
    for (textile_fixtures) |f| {
        var result = try oliver.parse(std.testing.allocator, f.input, .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
}
