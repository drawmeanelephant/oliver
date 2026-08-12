//! Textile frontend.
//!
//! Vertical slice: paragraphs, `h1.`–`h6.` headings, and plain inline text
//! with line breaks. Behavior is chosen from the published user-facing Textile
//! documentation (Hobix reference; Movable Type "Textile 2 Syntax") where the
//! slice implements it; disagreements between versions and Oliver's chosen
//! resolutions are recorded in docs/FEATURE-MATRIX.md.
//!
//! Chosen behaviors for this slice:
//! - Blocks are separated by blank lines.
//! - A block marker (`hN.`, `p.`) must be followed by a space or tab to count
//!   as a marker; otherwise the line is ordinary paragraph text.
//! - Marker lines start a new block even without a preceding blank line
//!   (recorded ambiguity; see docs/FEATURE-MATRIX.md).
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
    var paragraph: ?Paragraph = null;
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            try closeParagraph(doc, &paragraph);
            continue;
        }
        if (tryHeading(line)) |heading| {
            try closeParagraph(doc, &paragraph);
            try emitHeading(doc, line, heading);
            continue;
        }
        if (tryParagraphMarker(line)) |content| {
            try appendParagraphContent(doc, &paragraph, content, line.terminatorSpan());
            continue;
        }
        try appendParagraphContent(doc, &paragraph, line.contentSpan(), line.terminatorSpan());
    }
    try closeParagraph(doc, &paragraph);
}

const Paragraph = struct {
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

/// Appends a paragraph line whose content span is already known (either the
/// whole line or the line after a stripped `p.` marker).
fn appendParagraphContent(
    doc: *document.Document,
    paragraph: *?Paragraph,
    content: source.Span,
    terminator: source.Span,
) ParseError!void {
    if (paragraph.* == null) {
        paragraph.* = .{ .start = content.start };
    }
    try paragraph.*.?.lines.append(doc.allocator(), .{
        .content = content,
        .terminator = terminator,
    });
}

fn closeParagraph(doc: *document.Document, paragraph: *?Paragraph) ParseError!void {
    const p = paragraph.* orelse return;
    paragraph.* = null;

    const lines = p.lines.items;
    const span = source.Span{
        .start = p.start,
        .end = lines[lines.len - 1].content.end,
    };
    const node = try doc.createNode(.paragraph, span, .none);
    try doc.appendChild(doc.root, node);

    for (lines, 0..) |ref, i| {
        if (i > 0) {
            const brk = try doc.createNode(.hard_break, ref.terminator, .none);
            try doc.appendChild(node, brk);
        }
        const text_node = try doc.createNode(.text, ref.content, .{
            .text = doc.text(ref.content),
        });
        try doc.appendChild(node, text_node);
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
