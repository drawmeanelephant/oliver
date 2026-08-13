//! Deterministic HTML rendering from the normalized document model.
//!
//! Rendering depends only on the document, never on the dialect that produced
//! it, and never reparses source. See docs/ARCHITECTURE.md ("HTML output
//! policy") for the explicit policies this renderer follows:
//!
//! - Text is escaped: `&` `&amp;`, `<` `&lt;`, `>` `&gt;`, `"` `&quot;`;
//!   NUL (U+0000) is emitted as U+FFFD.
//! - Link attributes: `href` is percent-encoded (a deliberate, documented
//!   policy derived from the spec examples: encode everything except
//!   alphanumerics and `-_.~!*'(),;:&=+$#@/%?`) and then HTML-escaped;
//!   `title` is HTML-escaped without percent-encoding. Attributes are
//!   emitted in the fixed order `href` then `title`, in double quotes.
//! - Images render as a void element `<img src="..." alt="..."
//!   title="..." />` under `void_trailing_slash`. `src` uses the same
//!   percent-encoding + HTML-escaping policy as `href`; `alt` is always
//!   emitted (possibly empty) and HTML-escaped like text; `title` only
//!   when present. Attribute order is fixed: `src`, `alt`, `title`.
//! - Headings use the level 1..6 (clamped for hand-built documents).
//! - Code spans render `<code>...</code>` with the same escaping as text.
//! - Code blocks render `<pre><code>...</code></pre>`; the first word of an
//!   info string becomes an escaped `language-...` class.
//! - Raw HTML leaves write their source spans verbatim, without escaping;
//!   this is the one inline form whose bytes can include source line endings.
//! - Lists render as `<ul>`/`<ol>` with `<li>` children; tight-list direct
//!   paragraphs omit `<p>`, while loose-list paragraphs retain it.
//! - Thematic breaks render as `<hr />` by default (or `<hr>` when the void
//!   trailing-slash option is disabled).
//! - Tables (GFM §4.10) render `<table>` with `<thead>` and `<tbody>`
//!   sections; the first row is the header (`<th>`), the rest body
//!   (`<td>`). Aligned columns carry an `align` attribute
//!   (left/center/right). `<tbody>` is omitted when the table has no body
//!   rows. Cells render inline content like a paragraph.
//! - Generated line endings in output are always `\n`; raw HTML source spans
//!   retain their original line-ending bytes by design.
//! - Every block-level element is followed by exactly one `\n`, so nonempty
//!   output always ends with `\n`.
//! - Void elements are emitted as `<br />` by default (CommonMark reference
//!   style), toggleable via `RenderOptions`.
//!
//! Traversal uses an explicit stack rather than recursion, so rendering a
//! hostile, deeply nested document cannot overflow the call stack.

const std = @import("std");
const document = @import("document.zig");
const entities = @import("entities.zig");

pub const RenderOptions = struct {
    /// Emit void elements with a trailing slash (`<br />`) instead of the
    /// HTML5 form (`<br>`). Defaults to the CommonMark reference style.
    void_trailing_slash: bool = true,
};

/// Renders `doc` to `writer`.
///
/// `writer` may be any value with a `writeAll([]const u8) !void` method;
/// pass a pointer to it. In Zig 0.16, `std.Io.Writer` values (e.g. from
/// `std.Io.Writer.Allocating` or `std.Io.File.writer`) satisfy this.
///
/// `gpa` is used only for the temporary traversal stack; nothing is retained.
pub fn render(gpa: std.mem.Allocator, writer: anytype, doc: *const document.Document, options: RenderOptions) !void {
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, .{ .enter = .{
        .node = doc.root,
        .tight_item = false,
        .suppress_p = false,
        .prefix_newline = false,
    } });
    while (stack.pop()) |frame| {
        switch (frame) {
            .enter => |f| {
                if (f.prefix_newline) try writer.writeByte('\n');
                try writeOpen(gpa, writer, &stack, f.node, f.suppress_p, options, doc.src.bytes);
                try pushChildren(gpa, &stack, f.node, f.tight_item);
            },
            .marker => |text| try writer.writeAll(text),
            .exit => |f| try writeClose(writer, f.node, f.suppress_p, options),
        }
    }
}

const Frame = union(enum) {
    enter: struct {
        node: *const document.Node,
        /// True when `node` is a `.list_item` of a tight list; passed to
        /// `pushChildren` so the item's direct paragraph children know to
        /// render without `<p>` (§5.3).
        tight_item: bool,
        /// True when `node` is a `.paragraph` whose direct parent is a
        /// tight list's item: render without `<p>`.
        suppress_p: bool,
        /// Some block children of a list item need a line break before their
        /// opening tag. Tight paragraphs do not emit a trailing newline, so
        /// a following nested block supplies that separator here; the first
        /// block in a loose item also starts on the line after `<li>`.
        prefix_newline: bool,
    },
    /// Literal output emitted when popped, used for the `<thead>`/`<tbody>`
    /// transitions between a table's header row and its body rows.
    marker: []const u8,
    /// `suppress_p` mirrors the decision made at open time, so the close
    /// tag matches.
    exit: struct { node: *const document.Node, suppress_p: bool },
};

fn pushChildren(
    gpa: std.mem.Allocator,
    stack: *std.ArrayList(Frame),
    node: *const document.Node,
    node_tight_item: bool,
) !void {
    // A table's children are rows; the first is the header row, the rest
    // body rows. The `<thead>`/`<tbody>` split is emitted between them as
    // marker frames (GFM §4.10 output; no `<tbody>` with no body rows).
    // The table's own exit frame was already pushed by `writeOpen`.
    if (node.tag == .table) {
        const n = node.children.items.len;
        const has_body = n >= 2;
        var i = n;
        while (i > 1) {
            i -= 1;
            try stack.append(gpa, .{ .enter = .{
                .node = node.children.items[i],
                .tight_item = false,
                .suppress_p = false,
                .prefix_newline = false,
            } });
        }
        try stack.append(gpa, .{ .marker = if (has_body) "</thead>\n<tbody>\n" else "</thead>\n" });
        try stack.append(gpa, .{ .enter = .{
            .node = node.children.items[0],
            .tight_item = false,
            .suppress_p = false,
            .prefix_newline = false,
        } });
        try stack.append(gpa, .{ .marker = "<thead>\n" });
        return;
    }
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        const c = node.children.items[i];
        // An item's direct paragraph children are suppressed iff its list
        // is tight; a list's children (items) carry the tight flag for
        // their own children.
        const tight = c.tag == .list_item and node.tag == .list and !node.data.list.loose;
        const suppress = c.tag == .paragraph and node.tag == .list_item and node_tight_item;
        var prefix_newline = false;
        if (node.tag == .list_item) {
            if (c.tag == .paragraph) {
                // A loose item's first paragraph starts after the opening
                // tag; tight paragraphs are inline with it. Later paragraphs
                // already follow a block's newline (or make the list loose).
                prefix_newline = !node_tight_item and i == 0;
            } else {
                // Nested containers and other block children always start
                // on a new line when first. A nested block following a tight
                // paragraph needs the separator that the suppressed
                // paragraph deliberately does not emit.
                prefix_newline = i == 0 or
                    (node_tight_item and i > 0 and node.children.items[i - 1].tag == .paragraph);
            }
        }
        try stack.append(gpa, .{ .enter = .{
            .node = c,
            .tight_item = tight,
            .suppress_p = suppress,
            .prefix_newline = prefix_newline,
        } });
    }
}

fn writeOpen(
    gpa: std.mem.Allocator,
    writer: anytype,
    stack: *std.ArrayList(Frame),
    node: *const document.Node,
    suppress_p: bool,
    options: RenderOptions,
    src: []const u8,
) !void {
    switch (node.tag) {
        .document => {
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .block_quote => {
            try writer.writeAll("<blockquote>\n");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .table => {
            try writer.writeAll("<table>\n");
            // Children (rows with thead/tbody markers) are pushed by
            // `pushChildren`; only the exit frame is set here.
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .table_row => {
            try writer.writeAll("<tr>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .table_cell => {
            const cell = node.data.table_cell;
            try writer.writeAll("\n<");
            try writer.writeAll(if (cell.header) "th" else "td");
            switch (cell.alignment) {
                .none => {},
                .left => try writer.writeAll(" align=\"left\""),
                .center => try writer.writeAll(" align=\"center\""),
                .right => try writer.writeAll(" align=\"right\""),
            }
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .list => {
            const list = node.data.list;
            switch (list.kind) {
                .bullet => try writer.writeAll("<ul>\n"),
                .ordered => {
                    if (list.start == 1) {
                        try writer.writeAll("<ol>\n");
                    } else {
                        var buf: [32]u8 = undefined;
                        const tag = try std.fmt.bufPrint(&buf, "<ol start=\"{d}\">\n", .{list.start});
                        try writer.writeAll(tag);
                    }
                },
            }
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .list_item => {
            try writer.writeAll("<li>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .paragraph => {
            // §5.3: a paragraph directly in a tight list's item renders
            // without `<p>` (`suppress_p` is computed at push time).
            if (!suppress_p) try writer.writeAll("<p>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = suppress_p } });
        },
        .heading => {
            const level = clampHeading(node.data.heading);
            var buf: [8]u8 = undefined;
            const tag = try std.fmt.bufPrint(&buf, "<h{d}>", .{level});
            try writer.writeAll(tag);
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .thematic_break => {
            try writer.writeAll(if (options.void_trailing_slash) "<hr />\n" else "<hr>\n");
        },
        .code_block => {
            const code = node.data.code_block;
            try writer.writeAll("<pre><code");
            if (code.info) |info| {
                const language_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
                if (language_end > 0) {
                    try writer.writeAll(" class=\"language-");
                    try writeEscaped(writer, info[0..language_end]);
                    try writer.writeByte('"');
                }
            }
            try writer.writeByte('>');
            try writeEscaped(writer, code.content);
            try writer.writeAll("</code></pre>\n");
        },
        .html_block => {
            // Leaf block: the verbatim container-stripped source lines, no
            // escaping (the raw-HTML policy of docs/RAW-HTML.md §3). Every
            // block is followed by exactly one `\n`, so an unterminated
            // final line gets one here (the reference implementation's
            // `cr()`).
            const content = node.data.html_block;
            try writer.writeAll(content);
            if (content.len == 0 or content[content.len - 1] != '\n') try writer.writeByte('\n');
        },
        .emphasis => {
            try writer.writeAll("<em>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .strong => {
            try writer.writeAll("<strong>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .bold => {
            // Textile `**x**` renders `<b>` (docs/FEATURE-MATRIX.md, Textile
            // inlines); Markdown never produces this tag.
            try writer.writeAll("<b>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .italic => {
            // Textile `__x__` renders `<i>` (docs/FEATURE-MATRIX.md, Textile
            // inlines); Markdown never produces this tag.
            try writer.writeAll("<i>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .deleted => {
            try writer.writeAll("<del>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .inserted => {
            try writer.writeAll("<ins>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .superscript => {
            try writer.writeAll("<sup>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .subscript => {
            try writer.writeAll("<sub>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .span => {
            // Textile `%x%` renders `<span>` without attributes; the
            // attribute-bearing forms are a later milestone.
            try writer.writeAll("<span>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .code_span => {
            try writer.writeAll("<code>");
            // Leaf tag: the (normalized) content is escaped like text
            // (& < > " and NUL -> U+FFFD), written on enter.
            try writeEscaped(writer, node.data.code_span);
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .link => {
            try writer.writeAll("<a href=\"");
            try writeEscapedHref(writer, node.data.link.href);
            try writer.writeByte('\"');
            if (node.data.link.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('\"');
            }
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false } });
        },
        .autolink => {
            // Leaf tag: one <a> with the raw label as its text. The href
            // follows the link href policy (percent-encode + HTML-escape);
            // the label is the raw content HTML-escaped like text
            // (docs/AUTOLINKS.md §3). No title, fixed attribute order.
            try writer.writeAll("<a href=\"");
            try writeEscapedHref(writer, node.data.autolink.href);
            try writer.writeAll("\">");
            try writeEscaped(writer, node.data.autolink.label);
            try writer.writeAll("</a>");
        },
        .image => {
            // Void element: the whole tag is written on enter and no exit
            // frame is pushed (leaf tag, no children). `src` follows the
            // href policy; `alt` is always emitted (possibly empty) and
            // HTML-escaped like text; `title` only when present.
            try writer.writeAll("<img src=\"");
            try writeEscapedHref(writer, node.data.image.src);
            try writer.writeAll("\" alt=\"");
            try writeEscaped(writer, node.data.image.alt);
            try writer.writeByte('\"');
            if (node.data.image.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('\"');
            }
            try writer.writeAll(if (options.void_trailing_slash) " />" else ">");
        },
        .text => try writeEscapedText(writer, node.data.text),
        .raw_html => {
            // Leaf tag: the raw source bytes of the construct, verbatim —
            // no escaping (docs/RAW-HTML.md §3). The span may include line
            // endings inside a multi-line tag.
            try writer.writeAll(src[node.span.start..node.span.end]);
        },
        .soft_break => try writer.writeAll("\n"),
        .hard_break => {
            try writer.writeAll(if (options.void_trailing_slash) "<br />" else "<br>");
            try writer.writeAll("\n");
        },
    }
}

fn writeClose(writer: anytype, node: *const document.Node, suppress_p: bool, options: RenderOptions) !void {
    _ = options;
    switch (node.tag) {
        .document => {},
        .block_quote => try writer.writeAll("</blockquote>\n"),
        .table => {
            // The thead/tbody split is emitted by marker frames between the
            // rows; only the tail (tbody close, table close) is written here.
            if (node.children.items.len >= 2) try writer.writeAll("</tbody>\n");
            try writer.writeAll("</table>\n");
        },
        .table_row => try writer.writeAll("\n</tr>\n"),
        .table_cell => {
            try writer.writeAll(if (node.data.table_cell.header) "</th>" else "</td>");
        },
        .list => {
            switch (node.data.list.kind) {
                .bullet => try writer.writeAll("</ul>\n"),
                .ordered => try writer.writeAll("</ol>\n"),
            }
        },
        .list_item => try writer.writeAll("</li>\n"),
        .paragraph => {
            if (suppress_p) {
                // Tight-list paragraphs are inline content of `<li>`; a
                // following block gets its own leading newline in its frame.
            } else {
                try writer.writeAll("</p>\n");
            }
        },
        .heading => {
            const level = clampHeading(node.data.heading);
            var buf: [8]u8 = undefined;
            const tag = try std.fmt.bufPrint(&buf, "</h{d}>\n", .{level});
            try writer.writeAll(tag);
        },
        .emphasis => try writer.writeAll("</em>"),
        .strong => try writer.writeAll("</strong>"),
        .bold => try writer.writeAll("</b>"),
        .italic => try writer.writeAll("</i>"),
        .deleted => try writer.writeAll("</del>"),
        .inserted => try writer.writeAll("</ins>"),
        .superscript => try writer.writeAll("</sup>"),
        .subscript => try writer.writeAll("</sub>"),
        .span => try writer.writeAll("</span>"),
        .code_span => try writer.writeAll("</code>"),
        .link => try writer.writeAll("</a>"),
        // These tags never push exit frames.
        .thematic_break, .code_block, .html_block, .text, .image, .autolink, .raw_html, .soft_break, .hard_break => unreachable,
    }
}

/// Heading levels are clamped to 1..6 so hand-built documents with invalid
/// levels still render deterministically. Dialect frontends only produce
/// valid levels, so clamping is purely defensive.
fn clampHeading(level: u8) u8 {
    return @min(@max(level, 1), 6);
}

/// Percent-encodes the href per Oliver's documented URL policy (see the
/// module comment), then HTML-escapes the result (`&` -> `&amp;`; the other
/// specials were already percent-encoded). Non-ASCII bytes are each encoded
/// as `%XX` (uppercase hex), a renderer choice the spec explicitly leaves
/// open.
fn writeEscapedHref(writer: anytype, href: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < href.len) : (i += 1) {
        const b = href[i];
        // `&` is URL-safe (kept unencoded) but must be `&amp;` inside an
        // HTML attribute value; the other attribute specials (`< > "`)
        // were already percent-encoded.
        if (b == '&') {
            if (i > start) try writer.writeAll(href[start..i]);
            try writer.writeAll("&amp;");
            start = i + 1;
            continue;
        }
        if (hrefSafe(b)) continue;
        if (i > start) try writer.writeAll(href[start..i]);
        var buf: [3]u8 = undefined;
        const hex = "0123456789ABCDEF";
        buf[0] = '%';
        buf[1] = hex[b >> 4];
        buf[2] = hex[b & 0xF];
        try writer.writeAll(&buf);
        start = i + 1;
    }
    if (start < href.len) try writer.writeAll(href[start..]);
}

/// URL-safe characters, i.e. left unpercent-encoded: RFC 3986 unreserved
/// (`A-Za-z0-9-._~`) plus the sub-delims (`!$&'()*+,;=`) and the reserved
/// chars the spec examples keep unencoded (`:/?#@`) plus `%` (existing
/// escapes are left alone; "all URL-escaped characters are also valid URL
/// characters"). Everything else — space, `"`, `\`, `<`, `>`, backtick,
/// brackets, control chars, and all non-ASCII — is percent-encoded. `&` is
/// URL-safe but still HTML-escaped to `&amp;` in the attribute (see
/// `writeEscapedHref`).
fn hrefSafe(b: u8) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '_', '.', '~', '!', '*', '\'', '(', ')', ',', ';', ':', '&', '=', '+', '$', '#', '@', '/', '?', '%' => true,
        else => false,
    };
}

/// Escapes text content. `&`, `<`, `>`, and `"` are escaped (the set the
/// CommonMark reference output escapes); NUL is replaced with U+FFFD.
fn writeEscaped(writer: anytype, text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const replacement: []const u8 = switch (text[i]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            0 => "\xEF\xBF\xBD", // U+FFFD
            else => continue,
        };
        if (i > start) try writer.writeAll(text[start..i]);
        try writer.writeAll(replacement);
        start = i + 1;
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}

/// Escapes text content after decoding §2.5 entity and numeric character
/// references: the decoded character is escaped like any other text byte,
/// so `&amp;` renders as `&amp;`, `&#X22;` as `&quot;`, and `&ouml;` as
/// `ö`. Text nodes borrow the source (docs/DOCUMENT-MODEL.md invariant 9),
/// so entity decoding happens here at render time, exactly where the
/// delimiter scanner and inline matcher can no longer see it (an
/// entity-produced `*` is text, never an emphasis delimiter). Code spans
/// and code blocks keep `writeEscaped` — references are literal there.
fn writeEscapedText(writer: anytype, text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (entities.decodeAt(text, i)) |dec| {
                if (i > start) try writeEscaped(writer, text[start..i]);
                try writeEscaped(writer, dec.bytes[0..dec.len]);
                i = dec.next;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    if (start < text.len) try writeEscaped(writer, text[start..]);
}

// ---------------------------------------------------------------------------
// Tests: rendering directly from hand-constructed documents, independent of
// either dialect frontend.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderDoc(doc: *document.Document) !std.ArrayList(u8) {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, doc, .{});
    return aw.toArrayList();
}

fn addText(doc: *document.Document, parent: *document.Node, text: []const u8) !void {
    const node = try doc.createNode(.text, .{ .start = 0, .end = @intCast(text.len) }, .{ .text = text });
    try doc.appendChild(parent, node);
}

test "html: escaping" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "a & b < c > d \" e \x00 f");
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p>a &amp; b &lt; c &gt; d &quot; e \u{FFFD} f</p>\n", out.items);
}

test "html: soft vs hard breaks and void option" {
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "a");
        try doc.appendChild(p, try doc.createNode(.soft_break, .{ .start = 0, .end = 0 }, .none));
        try addText(&doc, p, "b");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a\nb</p>\n", out.items);
    }
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "a");
        try doc.appendChild(p, try doc.createNode(.hard_break, .{ .start = 0, .end = 0 }, .none));
        try addText(&doc, p, "b");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a<br />\nb</p>\n", out.items);

        // void_trailing_slash = false gives HTML5-style <br>.
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
        var out2 = aw.toArrayList();
        defer out2.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a<br>\nb</p>\n", out2.items);
    }
}

test "html: heading clamp and empty document" {
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = 0 }));
        try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = 7 }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<h1></h1>\n<h6></h6>\n", out.items);
    }
    {
        // Empty document renders to empty output.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("", out.items);
    }
}

test "html: emphasis and strong render from hand-built documents" {
    // Renderer-only: emphasis/strong nodes built by hand, not parsed — the
    // renderer consumes the model, not the dialect (docs/INLINE-PARSING.md
    // §15, "Renderer-only").
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(doc.root, p);
    const em = try doc.createNode(.emphasis, .{ .start = 0, .end = 12 }, .none);
    try doc.appendChild(p, em);
    try addText(&doc, em, "a ");
    const strong = try doc.createNode(.strong, .{ .start = 3, .end = 9 }, .none);
    try doc.appendChild(em, strong);
    try addText(&doc, strong, "b");
    try addText(&doc, em, " c");
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><em>a <strong>b</strong> c</em></p>\n", out.items);
}

test "html: code span content is escaped, not re-parsed" {
    // Renderer-only: a hand-built code_span with markup-ish payload must
    // render the payload escaped inside <code> — the renderer never treats
    // code_span content as inline markup (leaf inline, docs/DOCUMENT-MODEL).
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(doc.root, p);
    const cs = try doc.createNode(.code_span, .{ .start = 0, .end = 14 }, .{ .code_span = "a <b>& \"c\"`" });
    try doc.appendChild(p, cs);
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><code>a &lt;b&gt;&amp; &quot;c&quot;`</code></p>\n", out.items);
}

test "html: raw HTML leaves write source spans verbatim" {
    const input = "<b>&</b>";
    var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = @intCast(input.len) }, .none);
    try doc.appendChild(doc.root, p);
    try doc.appendChild(p, try doc.createNode(.raw_html, .{ .start = 0, .end = 3 }, .none));
    try doc.appendChild(p, try doc.createNode(.text, .{ .start = 3, .end = 4 }, .{ .text = doc.text(.{ .start = 3, .end = 4 }) }));
    try doc.appendChild(p, try doc.createNode(.raw_html, .{ .start = 4, .end = 8 }, .none));

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><b>&amp;</b></p>\n", out.items);
}

test "html: link renders href and title with escaping policy" {
    // Renderer-only: hand-built link nodes — the renderer consumes the
    // model, never the dialect (docs/DOCUMENT-MODEL.md).
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/uri", .title = "the title" },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "foo");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/uri\" title=\"the title\">foo</a></p>\n", out.items);
    }
    {
        // href percent-encoding: space, quote, backslash, and non-ASCII are
        // encoded; `&` is HTML-escaped; safe URL chars stay.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/my url\"\\foo()a&b", .title = null },
        });
        try doc.appendChild(p, lnk);
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/my%20url%22%5Cfoo()a&amp;b\"></a></p>\n", out.items);
    }
    {
        // title escaping: HTML-escaped, no percent-encoding.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/u", .title = "a \"b\" & <c>" },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "x");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/u\" title=\"a &quot;b&quot; &amp; &lt;c&gt;\">x</a></p>\n", out.items);
    }
    {
        // No title attribute when the title is absent.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/u", .title = null },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "x");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/u\">x</a></p>\n", out.items);
    }
}

test "html: image renders as a void element with fixed attribute order" {
    // Renderer-only: hand-built image nodes — the renderer consumes the
    // model, never the dialect (docs/IMAGES-PARSING.md §4).
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/uri", .alt = "foo", .title = "the title" },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/uri\" alt=\"foo\" title=\"the title\" /></p>\n", out.items);
    }
    {
        // Empty alt is always emitted; no title attribute when absent.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/u", .alt = "", .title = null },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/u\" alt=\"\" /></p>\n", out.items);
    }
    {
        // src percent-encoding follows the href policy; alt and title are
        // HTML-escaped like text.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/my url\"&x", .alt = "a <b> & \"c\"", .title = "t&t" },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings(
            "<p><img src=\"/my%20url%22&amp;x\" alt=\"a &lt;b&gt; &amp; &quot;c&quot;\" title=\"t&amp;t\" /></p>\n",
            out.items,
        );
    }
    {
        // void_trailing_slash = false gives the HTML5-style <img>.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/u", .alt = "a", .title = null },
        }));
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/u\" alt=\"a\"></p>\n", out.items);
    }
}

test "html: tight and loose lists keep block framing deterministic" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const list = try doc.createNode(.list, .{ .start = 0, .end = 0 }, .{ .list = .{
        .kind = .bullet,
        .bullet = '-',
        .loose = false,
    } });
    try doc.appendChild(doc.root, list);

    const first = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(list, first);
    const first_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(first, first_p);
    try addText(&doc, first_p, "one");

    const nested = try doc.createNode(.list, .{ .start = 0, .end = 0 }, .{ .list = .{
        .kind = .ordered,
        .delimiter = '.',
        .start = 3,
    } });
    try doc.appendChild(first, nested);
    const nested_item = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(nested, nested_item);
    const nested_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(nested_item, nested_p);
    try addText(&doc, nested_p, "three");

    const second = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(list, second);
    const second_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(second, second_p);
    try addText(&doc, second_p, "two");

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<ul>\n<li>one\n<ol start=\"3\">\n<li>three</li>\n</ol>\n</li>\n<li>two</li>\n</ul>\n",
        out.items,
    );

    list.data.list.loose = true;
    var loose_out = try renderDoc(&doc);
    defer loose_out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<ul>\n<li>\n<p>one</p>\n<ol start=\"3\">\n<li>three</li>\n</ol>\n</li>\n<li>\n<p>two</p>\n</li>\n</ul>\n",
        loose_out.items,
    );
}

test "html: mixed blocks render independently of dialect" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = 2 }));
    try doc.appendChild(doc.root, try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .none));
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<h2></h2>\n<p></p>\n", out.items);
}

test "html: table renders thead/tbody sections and alignment attributes" {
    // Renderer-only: a hand-built table — the renderer consumes the model,
    // never the dialect (docs/DOCUMENT-MODEL.md). Row 0 is the header row;
    // each cell carries its own header/alignment flags.
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const table = try doc.createNode(.table, .{ .start = 0, .end = 0 }, .{
        .table = .{ .alignment = &.{ .none, .center, .right } },
    });
    try doc.appendChild(doc.root, table);

    // Header row: three cells (plain, center-aligned, right-aligned).
    const header = try doc.createNode(.table_row, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(table, header);
    const h1 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .none } });
    try doc.appendChild(header, h1);
    try addText(&doc, h1, "foo");
    const h2 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .center } });
    try doc.appendChild(header, h2);
    try addText(&doc, h2, "bar");
    const h3 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .right } });
    try doc.appendChild(header, h3);
    try addText(&doc, h3, "baz");

    // One body row: padded to the table's three columns (an empty cell
    // renders <td></td>).
    const body = try doc.createNode(.table_row, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(table, body);
    const b1 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .none } });
    try doc.appendChild(body, b1);
    try addText(&doc, b1, "quux");
    const b2 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .center } });
    try doc.appendChild(body, b2);
    try doc.appendChild(body, try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .right } }));

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th align=\"center\">bar</th>\n<th align=\"right\">baz</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>quux</td>\n<td align=\"center\"></td>\n<td align=\"right\"></td>\n</tr>\n</tbody>\n</table>\n",
        out.items,
    );

    // No body rows: no <tbody> section is emitted.
    var doc2 = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc2.deinit();
    const t2 = try doc2.createNode(.table, .{ .start = 0, .end = 0 }, .{ .table = .{ .alignment = &.{.none} } });
    try doc2.appendChild(doc2.root, t2);
    const h = try doc2.createNode(.table_row, .{ .start = 0, .end = 0 }, .none);
    try doc2.appendChild(t2, h);
    const c = try doc2.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .none } });
    try doc2.appendChild(h, c);
    try addText(&doc2, c, "only");
    var out2 = try renderDoc(&doc2);
    defer out2.deinit(testing.allocator);
    try testing.expectEqualStrings("<table>\n<thead>\n<tr>\n<th>only</th>\n</tr>\n</thead>\n</table>\n", out2.items);
}

test "html: thematic break follows the void-element profile" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "***" });
    defer doc.deinit();
    try doc.appendChild(doc.root, try doc.createNode(.thematic_break, .{ .start = 0, .end = 3 }, .none));

    var default_out = try renderDoc(&doc);
    defer default_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<hr />\n", default_out.items);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
    var modern_out = aw.toArrayList();
    defer modern_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<hr>\n", modern_out.items);
}

test "html: code block escapes content and uses the first info word" {
    const input = "``` zig&lang extra\n<x>\x00\n```";
    var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
    defer doc.deinit();
    const code = try doc.createNode(.code_block, .{ .start = 0, .end = @intCast(input.len) }, .{
        .code_block = .{
            .content = "<x>\x00\n",
            .info = "zig&lang extra",
        },
    });
    try doc.appendChild(doc.root, code);

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<pre><code class=\"language-zig&amp;lang\">&lt;x&gt;\u{FFFD}\n</code></pre>\n",
        out.items,
    );
}
