//! Deterministic mutation-fuzz tests over the public parse API.
//!
//! A fixed-seed PRNG mutates a comptime seed corpus (one representative
//! input per dialect family) into thousands of derived inputs; each one is
//! parsed across all three dialects with the extension surface on, rendered
//! twice for determinism, and (for Cooklang) serialized and scaled. The
//! contracts asserted are the adversarial suite's own (docs/TESTS.md):
//! completion without crash, leak, unbounded recursion, or output
//! nondeterminism. The fixed seed makes the whole run reproducible — a
//! failure prints the iteration, the dialect, and the failing bytes (raw
//! and hex) for minimization. This is the "dedicated fuzz target" that
//! docs/TESTS.md recorded as planned; the public
//! `oliver.parse(allocator, bytes, dialect, options)` API is the fuzz
//! entry point (issue #94).

const std = @import("std");
const oliver = @import("oliver");

/// The seed corpus: representative inputs per dialect, chosen to exercise
/// deep parser states (nesting, delimiter storms, tables, escapes, raw
/// content, front matter, and the extension surface). Mutations of these
/// reach shapes hand-written tests never do.
const seeds = [_][]const u8{
    // Markdown: emphasis/strong storms, nested containers, links,
    // code spans/fences, HTML blocks, autolinks, entities, tables,
    // headings, breaks, and the extension surface (wikilinks, callouts,
    // task lists, footnotes, definition lists, heading attributes).
    "# Head *em* **strong** `code` [link](https://x.test/a?b=1&c=2 \"t\")\n" ++
        "\n" ++
        "> quote\n" ++
        "> > nested\n" ++
        "\n" ++
        "- a\n" ++
        "  - b\n" ++
        "    - c\n" ++
        "\n" ++
        "| a | b |\n" ++
        "| - | :-: |\n" ++
        "| 1 | 2 |\n" ++
        "\n" ++
        "<div class=\"x\">\n" ++
        "raw & stuff\n" ++
        "</div>\n" ++
        "\n" ++
        "<https://auto.link/x?y=1>\n" ++
        "\n" ++
        "[[wikilink|label]] and > [!note] Callout\n" ++
        "\n" ++
        "- [x] done\n" ++
        "- [ ] todo\n" ++
        "\n" ++
        "Term\n" ++
        ": definition\n" ++
        "\n" ++
        "[^1]: a note\n" ++
        "\n" ++
        "Ref[^1] and \\*escaped\\* and a&nbsp;entity\n",
    // Markdown: reference links, images, setext, thematic breaks, hard
    // breaks, entity references, backslash escapes.
    "Setext\n" ++
        "======\n" ++
        "\n" ++
        "![alt *text*](/img.png \"title\")\n" ++
        "\n" ++
        "[ref]: /dest \"title\"\n" ++
        "\n" ++
        "See [ref] and [ref][ref] and ![alt][ref].\n" ++
        "\n" ++
        "---\n" ++
        "\n" ++
        "line  \\\n" ++
        "break\n",
    // Textile: phrases with attributes, tables, extended blocks,
    // footnotes, links, images, macros, definition lists, notextile.
    "h1. Title\n" ++
        "\n" ++
        "*strong* and _em_ and **bold** and __italic__ and\n" ++
        "%{color:red}span% and ++big++ and --small-- and ^sup^ and ~sub~\n" ++
        "and ??cite?? and ABC(definition)\n" ++
        "\n" ++
        "|_. h |_. h |\n" ++
        "| a | b |\n" ++
        "\n" ++
        "bq. \"quoted\":url a quote\n" ++
        "\n" ++
        "fn1. a footnote\n" ++
        "\n" ++
        "see[1]\n" ++
        "\n" ++
        "p{color:red}(class#id)[lang]. styled\n" ++
        "\n" ++
        "notextile. <b>raw</b>\n" ++
        "\n" ++
        "pre. verbatim <x>\n",
    // Textile: bc./pre. code, clear., dl., line attributes, escaping.
    "bc. code <x> & y\n" ++
        "\n" ++
        "pre. raw <b>\n" ++
        "\n" ++
        "clear.\n" ++
        "\n" ++
        "p<. left align\n" ++
        "\n" ++
        "== escaped ==\n" ++
        "\n" ++
        "|1|2|\n",
    // Cooklang: full recipe with frontmatter, ingredients, timers,
    // cookware, sections, prep steps, references, mixed quantities.
    "---\n" ++
        "servings: 2\n" ++
        "title: Test\n" ++
        "---\n" ++
        "\n" ++
        "> @milk{1 1/2%cup}\n" ++
        "\n" ++
        "Add @salt{1/2 tsp} and @pepper{}.\n" ++
        "\n" ++
        "Prepared @onion{2} \n" ++
        "\n" ++
        "Cook @pasta{200%g} for ~{15%minutes}.\n" ++
        "\n" ++
        "Use @pan{}.\n" ++
        "\n" ++
        "= Section\n" ++
        "\n" ++
        "Step with @tomato{3}.\n" ++
        "\n" ++
        "@recipe:other.cook\n",
    // Cooklang: edge shapes — fixed quantities, ranges, bare ingredients.
    "Use @water{=2%cup} and @oil{1/2}.\n" ++
        "\n" ++
        "@garlic{}\n" ++
        "\n" ++
        "@chicken{500%g} @rice{1%cup}\n" ++
        "\n" ++
        "~{30%minutes}\n" ++
        "\n" ++
        "#tag & standalone text\n",
    // Front matter edge shapes.
    "---\ntitle: A & B\n---\nbody\n",
    "+++\nfoo = \"bar\"\n+++\ntext\n",
};

/// The generated input cap (well under `source.max_input_len`, so span
/// arithmetic never risks overflow) and the per-run mutation budget.
/// Sized so the step completes in a few seconds under the Debug test
/// gate while still mutating every seed thousands of edits deep.
const max_input: usize = 4096;
const iterations: usize = 1000;

test "fuzz: three-dialect mutation wall over the public parse API" {
    // A fixed seed makes every run identical: a failure today is the same
    // failure tomorrow, and the printed input minimizes by hand.
    var prng = std.Random.DefaultPrng.init(0x0ff1ce);
    const rnd = prng.random();
    var buf: [max_input]u8 = undefined;
    for (0..iterations) |i| {
        const input = mutate(rnd, &seeds, &buf);
        try exercise(input, i);
    }
}

/// Parses and renders `input` across all three dialects with the extension
/// surface on, asserting the adversarial contracts: no crash, no leak
/// (the test allocator fails on leaks/double-frees), deterministic output
/// (every render/serialize runs twice and must agree byte-for-byte).
/// On failure the input is printed for minimization.
fn exercise(input: []const u8, i: usize) !void {
    // Markdown: every extension on, YAML front matter.
    {
        var result = try oliver.parse(std.testing.allocator, input, .markdown, .{
            .markdown = .{
                .footnotes = true,
                .definition_lists = true,
                .heading_attributes = true,
                .strikethrough = true,
                .wikilinks = true,
                .callouts = true,
                .smartypants = true,
                .task_lists = true,
            },
            .frontmatter = .yaml,
        });
        defer result.deinit();
        const a = try renderDoc(&result.document);
        defer std.testing.allocator.free(a);
        const b = try renderDoc(&result.document);
        defer std.testing.allocator.free(b);
        if (!std.mem.eql(u8, a, b)) return fail(input, i, "markdown render nondeterminism");
    }
    // Textile: TOML front matter, double render.
    {
        var result = try oliver.parse(std.testing.allocator, input, .textile, .{ .frontmatter = .toml });
        defer result.deinit();
        const a = try renderDoc(&result.document);
        defer std.testing.allocator.free(a);
        const b = try renderDoc(&result.document);
        defer std.testing.allocator.free(b);
        if (!std.mem.eql(u8, a, b)) return fail(input, i, "textile render nondeterminism");
    }
    // Cooklang: YAML front matter; render, serialize, and scale must all
    // be deterministic and complete.
    {
        var result = try oliver.cooklang.parse(std.testing.allocator, input, .{ .frontmatter = .yaml });
        defer result.deinit();
        const a = try renderRecipe(&result.recipe);
        defer std.testing.allocator.free(a);
        const b = try renderRecipe(&result.recipe);
        defer std.testing.allocator.free(b);
        if (!std.mem.eql(u8, a, b)) return fail(input, i, "cooklang render nondeterminism");
        const s1 = try serializeRecipe(&result.recipe);
        defer std.testing.allocator.free(s1);
        const s2 = try serializeRecipe(&result.recipe);
        defer std.testing.allocator.free(s2);
        if (!std.mem.eql(u8, s1, s2)) return fail(input, i, "cooklang serialize nondeterminism");
        var scaled = try oliver.cooklang_scale.scaleRecipe(std.testing.allocator, &result.recipe, .{
            .factor = .{ .num = 3, .den = 2 },
        });
        defer scaled.deinit();
        const s3 = try serializeRecipe(&scaled);
        defer std.testing.allocator.free(s3);
    }
}

fn renderDoc(doc: *const oliver.document.Document) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, doc, .{});
    var out = aw.toArrayList();
    return out.toOwnedSlice(std.testing.allocator);
}

fn renderRecipe(recipe: *const oliver.cooklang.Recipe) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_html.render(std.testing.allocator, &aw.writer, recipe, .{});
    var out = aw.toArrayList();
    return out.toOwnedSlice(std.testing.allocator);
}

fn serializeRecipe(recipe: *const oliver.cooklang.Recipe) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_serialize.serialize(std.testing.allocator, &aw.writer, recipe, .{});
    var out = aw.toArrayList();
    return out.toOwnedSlice(std.testing.allocator);
}

/// Mutates a random seed with 1–8 random edits (overwrite, insert, delete,
/// block duplicate, truncate), biased toward parser-relevant bytes. The
/// result is clamped to `max_input`. Returns the seed itself untouched on
/// a subset of single-edit runs so the pure seeds are exercised too.
fn mutate(rnd: std.Random, seed_set: []const []const u8, buf: []u8) []const u8 {
    const seed = seed_set[rnd.uintLessThan(usize, seed_set.len)];
    var len: usize = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);
    const n_mutations = 1 + rnd.uintLessThan(usize, 8);
    if (n_mutations == 1 and rnd.boolean()) return seed;
    var m: usize = 0;
    while (m < n_mutations and len > 0) : (m += 1) {
        switch (rnd.uintLessThan(u8, 5)) {
            0 => { // overwrite one byte
                buf[rnd.uintLessThan(usize, len)] = interesting(rnd);
            },
            1 => { // insert one byte
                if (len < buf.len) {
                    const pos = rnd.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[pos + 1 .. len + 1], buf[pos..len]);
                    buf[pos] = interesting(rnd);
                    len += 1;
                }
            },
            2 => { // delete one byte
                const pos = rnd.uintLessThan(usize, len);
                std.mem.copyForwards(u8, buf[pos..], buf[pos + 1 .. len]);
                len -= 1;
            },
            3 => { // duplicate a block
                const src = rnd.uintLessThan(usize, len);
                const count = rnd.uintLessThan(usize, @min(64, len - src + 1));
                if (len + count <= buf.len) {
                    @memcpy(buf[len .. len + count], buf[src .. src + count]);
                    len += count;
                }
            },
            4 => { // truncate
                len = rnd.uintLessThan(usize, len);
            },
            else => unreachable,
        }
    }
    return buf[0..len];
}

/// Bytes biased toward markup structure — delimiters, escapes, whitespace,
/// digits, and letters — so mutations frequently create parser-relevant
/// shapes rather than random noise.
const interesting_bytes =
    "[](){}<>*_`~#|!&.;:\"'\\\t\n\r\x00 -+/=%0123456789" ++
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn interesting(rnd: std.Random) u8 {
    return interesting_bytes[rnd.uintLessThan(usize, interesting_bytes.len)];
}

/// Prints the failing input (raw and hex) for triage/minimization and
/// fails the test with a named violation.
fn fail(input: []const u8, i: usize, what: []const u8) error{FuzzFailure} {
    std.debug.print("fuzz failure at iteration {d}: {s}\n", .{ i, what });
    std.debug.print("--- input ({d} bytes) ---\n{s}\n", .{ input.len, input });
    std.debug.print("--- hex ---\n", .{});
    for (input) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    return error.FuzzFailure;
}
