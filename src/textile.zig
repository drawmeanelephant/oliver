//! Textile frontend.
//!
//! Vertical slice: paragraphs, `h1.`–`h6.` headings, single-period `bq.` block
//! quotes, and plain inline text with line breaks. Behavior is chosen from the
//! published user-facing Textile documentation (Hobix reference; Movable Type
//! "Textile 2 Syntax"; Textile Markup Language Documentation) where the slice
//! implements it; disagreements between versions and Oliver's chosen
//! resolutions are recorded in docs/FEATURE-MATRIX.md.
//!
//! Chosen behaviors for this slice:
//! - Blocks are separated by blank lines.
//! - A block marker (`hN.`, `p.`, `bq.`) must be followed by a space or tab to
//!   count as a marker; otherwise the line is ordinary paragraph text.
//! - Marker lines start a new block even without a preceding blank line
//!   (recorded ambiguity; see docs/FEATURE-MATRIX.md).
//! - A single-period `bq.` block continues through unmarked lines until a blank
//!   line or another recognized block marker. Its content is one paragraph
//!   inside a block quote. Extended `bq..` and citation `bq.:URL` forms remain
//!   literal until their separate milestones.
//! - `bq.` followed only by separator whitespace is literal: the user-facing
//!   documentation does not define an empty block-quote form.
//! - A newline inside a paragraph is a hard line break (Textile 2: "newlines
//!   for XHTML content receive a `<br />` tag at the end of the line").
//! - Paragraph content is preserved verbatim (only the marker's separator
//!   whitespace is consumed).
//! - `h0.` and `h7.`+ are not headings; they remain paragraph text.

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");
const diagnostic = @import("diagnostic.zig");

pub const ParseError = error{OutOfMemory};

/// Parses `doc.src` as Textile, appending block nodes under `doc.root`.
/// The caller (`oliver.parse`) guarantees the input fits in `u32` spans.
pub fn parse(doc: *document.Document, diags: *std.ArrayList(diagnostic.Diagnostic)) ParseError!void {
    _ = diags;

    var lines = source.Lines.init(doc.src.bytes);
    var block: ?ActiveBlock = null;
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            try closeBlock(doc, &block);
            continue;
        }
        if (tryHeading(line)) |heading| {
            try closeBlock(doc, &block);
            try emitHeading(doc, line, heading);
            continue;
        }
        if (tryParagraphMarker(line)) |content| {
            try closeBlock(doc, &block);
            try appendBlockContent(doc, &block, .paragraph, content, line.terminatorSpan());
            continue;
        }
        if (tryBlockQuoteMarker(line)) |content| {
            try closeBlock(doc, &block);
            try appendBlockContent(doc, &block, .block_quote, content, line.terminatorSpan());
            continue;
        }
        const kind: BlockKind = if (block) |active| active.kind else .paragraph;
        try appendBlockContent(doc, &block, kind, line.contentSpan(), line.terminatorSpan());
    }
    try closeBlock(doc, &block);
}

const BlockKind = enum { paragraph, block_quote };

const ActiveBlock = struct {
    kind: BlockKind,
    start: u32,
    lines: std.ArrayList(LineRef) = .empty,

    const LineRef = struct {
        content: source.Span,
        terminator: source.Span,
    };
};

fn isBlank(text: []const u8) bool {
    for (text) |b| {
        if (b != ' ' and b != '\t') return false;
    }
    return true;
}

/// Appends a line whose content span is already known (the whole line or the
/// line after a stripped block marker). A marked block is closed before this
/// function is called; unmarked lines pass the active block's existing kind.
fn appendBlockContent(
    doc: *document.Document,
    block: *?ActiveBlock,
    kind: BlockKind,
    content: source.Span,
    terminator: source.Span,
) ParseError!void {
    if (block.* == null) {
        block.* = .{ .kind = kind, .start = content.start };
    }
    std.debug.assert(block.*.?.kind == kind);
    try block.*.?.lines.append(doc.allocator(), .{
        .content = content,
        .terminator = terminator,
    });
}

fn closeBlock(doc: *document.Document, block: *?ActiveBlock) ParseError!void {
    const active = block.* orelse return;
    block.* = null;

    const lines = active.lines.items;
    const span = source.Span{
        .start = active.start,
        .end = lines[lines.len - 1].content.end,
    };
    var parent = doc.root;
    if (active.kind == .block_quote) {
        const quote = try doc.createNode(.block_quote, span, .none);
        try doc.appendChild(doc.root, quote);
        parent = quote;
    }
    const paragraph = try doc.createNode(.paragraph, span, .none);
    try doc.appendChild(parent, paragraph);

    for (lines, 0..) |ref, i| {
        if (i > 0) {
            // The break before this line covers the previous line's actual
            // terminator, including the full CRLF pair when present.
            const brk = try doc.createNode(.hard_break, lines[i - 1].terminator, .none);
            try doc.appendChild(paragraph, brk);
        }
        const text_node = try doc.createNode(.text, ref.content, .{
            .text = doc.text(ref.content),
        });
        try doc.appendChild(paragraph, text_node);
    }
}

const Heading = struct {
    level: u8,
    /// Content span (after the marker and its separator whitespace).
    content: source.Span,
};

/// Recognizes `h1.`–`h6.` block markers. The marker must be followed by a
/// space or tab (both references require a space after the signature's
/// period). Content is everything after the marker's separator whitespace,
/// preserved verbatim.
fn tryHeading(line: source.Line) ?Heading {
    const t = line.text;
    if (t.len < 3) return null;
    if (t[0] != 'h') return null;
    const digit = t[1];
    if (digit < '1' or digit > '6') return null;
    if (t[2] != '.') return null;
    if (t.len == 3) return null; // marker must be followed by a space/tab
    if (t[3] != ' ' and t[3] != '\t') return null;

    var i: usize = 3;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    return .{
        .level = digit - '0',
        .content = .{
            .start = @intCast(line.start + i),
            .end = @intCast(line.content_end),
        },
    };
}

/// Recognizes a `p.` paragraph marker, returning the content span after the
/// marker and its separator whitespace. `p.` without a following space/tab is
/// ordinary text.
fn tryParagraphMarker(line: source.Line) ?source.Span {
    const t = line.text;
    if (t.len < 3) return null;
    if (t[0] != 'p' or t[1] != '.') return null;
    if (t[2] != ' ' and t[2] != '\t') return null;
    var i: usize = 2;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    return .{
        .start = @intCast(line.start + i),
        .end = @intCast(line.content_end),
    };
}

/// Recognizes the single-period `bq.` block-quote signature. Published Textile
/// documentation requires a period followed by a space; Oliver consistently
/// accepts a tab as signature separator too. An empty content range is not a
/// quote: empty `bq.` behavior is unspecified by the documentation, so the
/// whole line remains literal. This also deliberately excludes the separately
/// documented extended (`bq..`) and citation (`bq.:URL`) forms.
fn tryBlockQuoteMarker(line: source.Line) ?source.Span {
    const t = line.text;
    if (t.len < 4) return null;
    if (!std.mem.eql(u8, t[0..3], "bq.")) return null;
    if (t[3] != ' ' and t[3] != '\t') return null;

    var i: usize = 3;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    if (i == t.len) return null;
    return .{
        .start = @intCast(line.start + i),
        .end = @intCast(line.content_end),
    };
}

fn emitHeading(doc: *document.Document, line: source.Line, heading: Heading) ParseError!void {
    const node = try doc.createNode(.heading, line.contentSpan(), .{
        .heading = heading.level,
    });
    try doc.appendChild(doc.root, node);
    try parseInlines(doc, node, heading.content);
}

/// Inline parsing seam: the slice emits one text node per non-empty content
/// range. Emphasis, links, images, code, attributes, and escaping are later
/// milestones (see docs/FEATURE-MATRIX.md).
fn parseInlines(doc: *document.Document, parent: *document.Node, content: source.Span) ParseError!void {
    if (content.isEmpty()) return;
    const node = try doc.createNode(.text, content, .{ .text = doc.text(content) });
    try doc.appendChild(parent, node);
}

test "textile: headings and paragraph structure" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "h1. One\n\np. Two\n\nh6. Six", .textile, .{});
    defer result.deinit();
    const root = result.document.root;
    try std.testing.expectEqual(document.Tag.heading, root.children.items[0].tag);
    try std.testing.expectEqual(@as(u8, 1), root.children.items[0].data.heading);
    try std.testing.expectEqualStrings("One", root.children.items[0].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    try std.testing.expectEqualStrings("Two", root.children.items[1].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.heading, root.children.items[2].tag);
    try std.testing.expectEqual(@as(u8, 6), root.children.items[2].data.heading);
}

test "textile: marker recognition edge cases" {
    const oliver = @import("oliver.zig");

    // h1. at end of line (no space) is not a heading.
    {
        var result = try oliver.parse(std.testing.allocator, "h1.", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // h0. is not a heading.
    {
        var result = try oliver.parse(std.testing.allocator, "h0. zero", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // p. at end of line is not a marker.
    {
        var result = try oliver.parse(std.testing.allocator, "p.", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // Multiple spaces after the marker are separator whitespace.
    {
        var result = try oliver.parse(std.testing.allocator, "p.   spaced", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqualStrings("spaced", result.document.root.children.items[0].children.items[0].data.text);
    }
}

test "textile: newlines become hard breaks in the model" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "a\nb", .textile, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    try std.testing.expectEqual(document.Tag.text, p.children.items[2].tag);
}

test "textile: explicit paragraph marker interrupts an open paragraph" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "First\np. Second\nThird", .textile, .{});
    defer result.deinit();

    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    const first = root.children.items[0];
    try std.testing.expectEqual(document.Tag.paragraph, first.tag);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 5 }, first.span);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 5 }, first.children.items[0].span);

    const second = root.children.items[1];
    try std.testing.expectEqual(document.Tag.paragraph, second.tag);
    try std.testing.expectEqual(source.Span{ .start = 9, .end = 21 }, second.span);
    try std.testing.expectEqualStrings("Second", second.children.items[0].data.text);
    try std.testing.expectEqual(source.Span{ .start = 9, .end = 15 }, second.children.items[0].span);
    try std.testing.expectEqual(document.Tag.hard_break, second.children.items[1].tag);
    try std.testing.expectEqual(source.Span{ .start = 15, .end = 16 }, second.children.items[1].span);
    try std.testing.expectEqualStrings("Third", second.children.items[2].data.text);
    try std.testing.expectEqual(source.Span{ .start = 16, .end = 21 }, second.children.items[2].span);
}

test "textile: hard-break spans cover LF CRLF and CR terminators" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "a\nb\r\nc\rd", .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 7), p.children.items.len);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    try std.testing.expectEqual(source.Span{ .start = 1, .end = 2 }, p.children.items[1].span);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[3].tag);
    try std.testing.expectEqual(source.Span{ .start = 3, .end = 5 }, p.children.items[3].span);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[5].tag);
    try std.testing.expectEqual(source.Span{ .start = 6, .end = 7 }, p.children.items[5].span);
}

test "textile: block quote uses shared IR with content-only spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "bq. café\r\nagain", .textile, .{});
    defer result.deinit();

    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    const quote = root.children.items[0];
    try std.testing.expectEqual(document.Tag.block_quote, quote.tag);
    try std.testing.expectEqual(source.Span{ .start = 4, .end = 16 }, quote.span);
    try std.testing.expectEqual(@as(usize, 1), quote.children.items.len);

    const p = quote.children.items[0];
    try std.testing.expectEqual(document.Tag.paragraph, p.tag);
    try std.testing.expectEqual(source.Span{ .start = 4, .end = 16 }, p.span);
    try std.testing.expectEqual(@as(usize, 3), p.children.items.len);
    try std.testing.expectEqualStrings("café", p.children.items[0].data.text);
    try std.testing.expectEqual(source.Span{ .start = 4, .end = 9 }, p.children.items[0].span);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    try std.testing.expectEqual(source.Span{ .start = 9, .end = 11 }, p.children.items[1].span);
    try std.testing.expectEqualStrings("again", p.children.items[2].data.text);
    try std.testing.expectEqual(source.Span{ .start = 11, .end = 16 }, p.children.items[2].span);
}

test "textile: empty extended and citation block-quote signatures stay literal" {
    const oliver = @import("oliver.zig");
    const cases = [_][]const u8{
        "bq.",
        "bq. \t",
        "bq.. Extended",
        "bq.:https://example.test/ Cited",
    };
    for (cases) |input| {
        var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
        defer result.deinit();
        const node = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, node.tag);
        try std.testing.expectEqualStrings(input, node.children.items[0].data.text);
    }
}

test "textile: block-quote signature flood stays iterative" {
    const oliver = @import("oliver.zig");
    const count = 10_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    for (0..count) |_| try input.appendSlice(std.testing.allocator, "bq. x\n");

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, count), result.document.root.children.items.len);
    try std.testing.expectEqual(document.Tag.block_quote, result.document.root.children.items[0].tag);
    try std.testing.expectEqual(document.Tag.block_quote, result.document.root.children.items[count - 1].tag);

    var first_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_writer.deinit();
    try oliver.html.render(std.testing.allocator, &first_writer.writer, &result.document, .{});
    var first = first_writer.toArrayList();
    defer first.deinit(std.testing.allocator);

    var second_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second_writer.deinit();
    try oliver.html.render(std.testing.allocator, &second_writer.writer, &result.document, .{});
    var second = second_writer.toArrayList();
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.items, second.items);
}
