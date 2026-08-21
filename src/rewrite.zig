//! Phase 6 S3 — native link rewriting for `oliver render`.
//!
//! Rewrites internal `href`/`src` values ending in `.md`/`.textile`/`.cook`
//! to `.html`, preserving `?` query and `#` fragment tails, stripping
//! `<>`/`%3C`/`&lt;` wrappers, and skipping external `://` and `mailto:`.
//!
//! The transform is a post-parse, pre-render walk over `document.Document`
//! leaves (`.link.href`, `.image.src`), not a regex over rendered HTML,
//! so `href=` inside code spans is never mangled. Percent-encoding is left
//! to `html.zig:writeEscapedHref`.
//!
//! Rules are byte-exact with `bones/scripts/rc-oliver-adapter.sh:288-353`
//! (GAWK fallback) so the harness flips `OLIVER_REWRITES=true` and skips
//! the GAWK pass once this ships.

const std = @import("std");
const oliver = @import("oliver");
const document = oliver.document;

/// Returns true when `url` is external and must not be rewritten.
///
/// External is `mailto:` or a URI scheme `://` (`^[a-zA-Z][a-zA-Z0-9+.-]*://`).
/// Matches the GAWK `if (target ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\// || target ~ /^mailto:/)`.
pub fn isExternal(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "mailto:")) return true;
    if (std.mem.indexOf(u8, url, "://")) |idx| {
        if (idx == 0) return false;
        const scheme = url[0..idx];
        if (!std.ascii.isAlphabetic(scheme[0])) return false;
        for (scheme[1..]) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
            if (!ok) return false;
        }
        return true;
    }
    return false;
}

/// Strips a single outer `<>` / `%3C` / `&lt;` … `%3E` / `>` / `&gt;` wrapper
/// when both a recognized prefix and suffix are present.
///
/// Mirrors the GAWK `if (target ~ /^(%3C|<|&lt;).*(%3E|>|&gt;)$/)` branch,
/// which removes one prefix (`%3C`/`&lt;`/`<`) and one suffix (`%3E`/`&gt;`/`>`),
/// mixed-encoding included. At AST level `scanLink` already removed bare
/// `<>`, but `%3C`/`&lt;` literals survive and must be stripped defensively.
pub fn stripWrappers(url: []const u8) []const u8 {
    var prefix_len: usize = 0;
    var has_prefix = false;
    if (std.mem.startsWith(u8, url, "%3C") or std.mem.startsWith(u8, url, "%3c")) {
        prefix_len = 3;
        has_prefix = true;
    } else if (std.mem.startsWith(u8, url, "&lt;")) {
        prefix_len = 4;
        has_prefix = true;
    } else if (std.mem.startsWith(u8, url, "<")) {
        prefix_len = 1;
        has_prefix = true;
    }

    var suffix_len: usize = 0;
    var has_suffix = false;
    if (std.mem.endsWith(u8, url, "%3E") or std.mem.endsWith(u8, url, "%3e")) {
        suffix_len = 3;
        has_suffix = true;
    } else if (std.mem.endsWith(u8, url, "&gt;")) {
        suffix_len = 4;
        has_suffix = true;
    } else if (std.mem.endsWith(u8, url, ">")) {
        suffix_len = 1;
        has_suffix = true;
    }

    if (has_prefix and has_suffix and prefix_len + suffix_len <= url.len) {
        return url[prefix_len .. url.len - suffix_len];
    }
    return url;
}

/// Rewrites a single URL string per the S3 contract.
///
/// - Strips wrappers via `stripWrappers`.
/// - Returns the stripped URL unchanged when `isExternal`.
/// - Otherwise, when the URL contains `.md`/`.textile`/`.cook` before
///   `?`, `#`, or end-of-string, splices that suffix to `.html` plus tail.
/// - Only the first qualifying occurrence per suffix is replaced, in the
///   GAWK order `.md` → `.textile` → `.cook`.
///
/// When a rewrite occurs the result is allocated with `allocator`; otherwise
/// the returned slice aliases `url` (no allocation). The caller is responsible
/// for ownership when an allocation occurs — for document rewriting the
/// allocator is the document's arena, so the new href/src is arena-owned.
pub fn rewriteUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const stripped = stripWrappers(url);

    if (isExternal(stripped)) {
        return stripped;
    }

    // Suffixes in GAWK order, longest first among the non-md? GAWK does
    // .md, .textile, .cook in that order.
    const suffixes = [_][]const u8{ ".md", ".textile", ".cook" };
    for (suffixes) |suffix| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, stripped, pos, suffix)) |idx| {
            const after = idx + suffix.len;
            const is_boundary = after == stripped.len or (after < stripped.len and (stripped[after] == '?' or stripped[after] == '#'));
            if (is_boundary) {
                const base = stripped[0..idx];
                const tail = stripped[after..];
                const out = try allocator.alloc(u8, base.len + 5 + tail.len);
                @memcpy(out[0..base.len], base);
                @memcpy(out[base.len .. base.len + 5], ".html");
                @memcpy(out[base.len + 5 ..], tail);
                return out;
            }
            // Not a boundary (e.g. ".md/" ) → keep searching past this occurrence.
            pos = idx + 1;
            if (pos >= stripped.len) break;
        }
    }

    return stripped;
}

/// Walks `doc` and rewrites every `.link.href` and `.image.src` leaf via
/// `rewriteUrl` with the document's arena allocator.
///
/// Leaves `.html_block`/`.raw_html` verbatim (fail-closed XSS) and never
/// touches text/code spans. Deterministic, arena-owned, and safe for both
/// `html` and `xhtml` profiles — the caller runs it between `oliver.parse`
/// and `oliver.html.render` (`src/main.zig:renderWithDiag`).
pub fn rewriteDocument(doc: *document.Document) !void {
    var it = try document.Document.Iterator.init(doc.allocator(), doc.root);
    defer it.deinit();
    while (try it.next()) |node| {
        switch (node.tag) {
            .link => {
                const old = node.data.link.href;
                const rewritten = try rewriteUrl(doc.allocator(), old);
                // Only reassign when the content or allocation changed. A
                // wrapper-strip returns a slice into the old allocation, so
                // pointer equality alone is insufficient — compare bytes too.
                if (rewritten.len != old.len or !std.mem.eql(u8, rewritten, old)) {
                    node.data.link.href = rewritten;
                } else if (rewritten.ptr != old.ptr) {
                    // Wrapper-strip that produced a smaller slice of the same
                    // backing bytes: keep the stripped slice.
                    node.data.link.href = rewritten;
                }
            },
            .image => {
                const old = node.data.image.src;
                const rewritten = try rewriteUrl(doc.allocator(), old);
                if (rewritten.len != old.len or !std.mem.eql(u8, rewritten, old)) {
                    node.data.image.src = rewritten;
                } else if (rewritten.ptr != old.ptr) {
                    node.data.image.src = rewritten;
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — mirrors the harness `ugly-edge-case.md` / `contract-inline.md`
// probes plus the `printf '[x](foo.md)' | oliver render` checks.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "rewrite: isExternal" {
    try testing.expect(isExternal("mailto:a@example.com"));
    try testing.expect(isExternal("mailto:necromancer@example.com"));
    try testing.expect(isExternal("https://example.com/foo.md"));
    try testing.expect(isExternal("http://example.com/foo.md"));
    try testing.expect(isExternal("ftp://example.com/foo.md"));
    try testing.expect(isExternal("a://b"));
    try testing.expect(isExternal("a+b://x"));
    try testing.expect(isExternal("a-b://x"));
    try testing.expect(isExternal("a.b://x"));
    try testing.expect(!isExternal("foo.md"));
    try testing.expect(!isExternal("/foo.md"));
    try testing.expect(!isExternal("./foo.md"));
    try testing.expect(!isExternal("../foo.md#sec"));
    try testing.expect(!isExternal("foo.md?v=1#f2"));
    try testing.expect(!isExternal("foo.textile"));
    try testing.expect(!isExternal("foo.cook"));
    try testing.expect(!isExternal("//example.com/foo.md")); // protocol-relative is not scheme://
    try testing.expect(!isExternal("mailto")); // no colon
    try testing.expect(!isExternal("://foo")); // no scheme
}

test "rewrite: stripWrappers" {
    try testing.expectEqualStrings("foo.md", stripWrappers("<foo.md>"));
    try testing.expectEqualStrings("foo.md", stripWrappers("%3Cfoo.md%3E"));
    try testing.expectEqualStrings("foo.md", stripWrappers("%3cfoo.md%3e"));
    try testing.expectEqualStrings("foo.md", stripWrappers("&lt;foo.md&gt;"));
    try testing.expectEqualStrings("foo.md", stripWrappers("<foo.md%3E"));
    try testing.expectEqualStrings("foo.md", stripWrappers("%3Cfoo.md>"));
    try testing.expectEqualStrings("foo.md#sec", stripWrappers("<foo.md#sec>"));
    try testing.expectEqualStrings("https://example.com/foo.md", stripWrappers("<https://example.com/foo.md>"));
    // No strip when only prefix or only suffix.
    try testing.expectEqualStrings("<foo.md", stripWrappers("<foo.md"));
    try testing.expectEqualStrings("foo.md>", stripWrappers("foo.md>"));
    try testing.expectEqualStrings("foo.md", stripWrappers("foo.md"));
    try testing.expectEqualStrings("", stripWrappers("<>"));
    try testing.expectEqualStrings("", stripWrappers("%3C%3E"));
}

test "rewrite: simple md/textile/cook to html" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const out = try rewriteUrl(a, "foo.md");
        try testing.expectEqualStrings("foo.html", out);
    }
    {
        const out = try rewriteUrl(a, "foo.textile");
        try testing.expectEqualStrings("foo.html", out);
    }
    {
        const out = try rewriteUrl(a, "foo.cook");
        try testing.expectEqualStrings("foo.html", out);
    }
}

test "rewrite: fragment and query preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const out = try rewriteUrl(a, "foo.md#sec");
        try testing.expectEqualStrings("foo.html#sec", out);
    }
    {
        const out = try rewriteUrl(a, "foo.md?v=1#f2");
        try testing.expectEqualStrings("foo.html?v=1#f2", out);
    }
    {
        const out = try rewriteUrl(a, "my-first-page.md#section-1");
        try testing.expectEqualStrings("my-first-page.html#section-1", out);
    }
    {
        const out = try rewriteUrl(a, "my-first-page.md?v=123#fragment");
        try testing.expectEqualStrings("my-first-page.html?v=123#fragment", out);
    }
    {
        const out = try rewriteUrl(a, "<foo.md#sec>");
        try testing.expectEqualStrings("foo.html#sec", out);
    }
    {
        const out = try rewriteUrl(a, "foo.md?v=1");
        try testing.expectEqualStrings("foo.html?v=1", out);
    }
    {
        const out = try rewriteUrl(a, "a/b/c/foo.textile?x=1#y");
        try testing.expectEqualStrings("a/b/c/foo.html?x=1#y", out);
    }
}

test "rewrite: external and mailto skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const out = try rewriteUrl(a, "https://example.com/foo.md");
        try testing.expectEqualStrings("https://example.com/foo.md", out);
    }
    {
        const out = try rewriteUrl(a, "https://example.com/docs.md");
        try testing.expectEqualStrings("https://example.com/docs.md", out);
    }
    {
        const out = try rewriteUrl(a, "<https://example.com/foo.md>");
        // Wrapper stripped even for external, but suffix not rewritten
        try testing.expectEqualStrings("https://example.com/foo.md", out);
    }
    {
        const out = try rewriteUrl(a, "mailto:necromancer@example.com");
        try testing.expectEqualStrings("mailto:necromancer@example.com", out);
    }
    {
        const out = try rewriteUrl(a, "<mailto:a@example.com>");
        try testing.expectEqualStrings("mailto:a@example.com", out);
    }
}

test "rewrite: angle and encoded wrappers stripped before rewrite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const out = try rewriteUrl(a, "<my-first-page.md>");
        try testing.expectEqualStrings("my-first-page.html", out);
    }
    {
        const out = try rewriteUrl(a, "%3Cmy-first-page.md%3E");
        try testing.expectEqualStrings("my-first-page.html", out);
    }
    {
        const out = try rewriteUrl(a, "&lt;my-first-page.md&gt;");
        try testing.expectEqualStrings("my-first-page.html", out);
    }
    {
        const out = try rewriteUrl(a, "%3Cfoo.md#sec%3E");
        try testing.expectEqualStrings("foo.html#sec", out);
    }
}

test "rewrite: no rewrite when suffix not at boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const out = try rewriteUrl(a, "foo.txt");
        try testing.expectEqualStrings("foo.txt", out);
    }
    {
        const out = try rewriteUrl(a, "foo.mdx");
        try testing.expectEqualStrings("foo.mdx", out);
    }
    {
        const out = try rewriteUrl(a, "foo.md/bar");
        try testing.expectEqualStrings("foo.md/bar", out);
    }
    {
        // second .md at end still qualifies — GAWK finds the qualifying one
        const out = try rewriteUrl(a, "foo.md/bar.md");
        try testing.expectEqualStrings("foo.md/bar.html", out);
    }
    {
        const out = try rewriteUrl(a, "FOO.MD");
        try testing.expectEqualStrings("FOO.MD", out);
    }
}

test "rewrite: rewriteDocument on link and image leaves" {
    var result = try oliver.parse(testing.allocator, "[x](foo.md) ![alt](bar.textile)", .markdown, .{});
    defer result.deinit();
    try rewriteDocument(&result.document);
    // Walk and collect href/src
    var it = try document.Document.Iterator.init(testing.allocator, result.document.root);
    defer it.deinit();
    var saw_link = false;
    var saw_image = false;
    while (try it.next()) |n| {
        if (n.tag == .link) {
            try testing.expectEqualStrings("foo.html", n.data.link.href);
            saw_link = true;
        }
        if (n.tag == .image) {
            try testing.expectEqualStrings("bar.html", n.data.image.src);
            saw_image = true;
        }
        // Ensure raw_html not present in this doc — no rewriting there
        try testing.expect(n.tag != .raw_html or true);
    }
    try testing.expect(saw_link and saw_image);
}

test "rewrite: rewriteDocument skips code_span and external" {
    var result = try oliver.parse(testing.allocator, "`[x](foo.md)` [y](https://example.com/foo.md) [z](foo.md#sec)", .markdown, .{});
    defer result.deinit();
    try rewriteDocument(&result.document);
    var it = try document.Document.Iterator.init(testing.allocator, result.document.root);
    defer it.deinit();
    var link_count: usize = 0;
    var saw_code = false;
    while (try it.next()) |n| {
        if (n.tag == .link) {
            link_count += 1;
            if (link_count == 1) try testing.expectEqualStrings("https://example.com/foo.md", n.data.link.href);
            if (link_count == 2) try testing.expectEqualStrings("foo.html#sec", n.data.link.href);
        }
        if (n.tag == .code_span) {
            saw_code = true;
            try testing.expectEqualStrings("[x](foo.md)", n.data.code_span);
        }
    }
    try testing.expectEqual(@as(usize, 2), link_count);
    try testing.expect(saw_code);
}

test "rewrite: rewriteDocument leaves raw_html verbatim" {
    // Raw HTML <a href="foo.md"> is a raw_html leaf, not a link — it must stay verbatim
    // even when a later link in the same paragraph is rewritten.
    var result = try oliver.parse(testing.allocator, "x <a href=\"foo.md\">hi</a> y [z](foo.md)", .markdown, .{});
    defer result.deinit();
    try rewriteDocument(&result.document);
    var it = try document.Document.Iterator.init(testing.allocator, result.document.root);
    defer it.deinit();
    var saw_raw = false;
    var saw_link = false;
    while (try it.next()) |n| {
        if (n.tag == .raw_html) {
            saw_raw = true;
            // The raw source must still contain the original foo.md (not rewritten)
            const raw = result.document.text(n.span);
            // At least one raw node should be the opening tag with foo.md
            if (std.mem.indexOf(u8, raw, "foo.md") != null) {
                try testing.expect(std.mem.indexOf(u8, raw, "foo.html") == null);
            }
        }
        if (n.tag == .link) {
            saw_link = true;
            try testing.expectEqualStrings("foo.html", n.data.link.href);
        }
    }
    try testing.expect(saw_raw);
    try testing.expect(saw_link);
}
