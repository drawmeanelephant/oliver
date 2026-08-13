//! Textile frontend.
//!
//! Vertical slice: paragraphs, `h1.`–`h6.` headings, single-period `bq.` block
//! quotes, `_`/`*` emphasis and strong phrases, plain inline text, and
//! same-line `@code@` phrases with line breaks.
//! Behavior is chosen from the published user-facing Textile documentation
//! (Hobix reference; Movable Type "Textile 2 Syntax"; Textile Markup Language
//! Documentation) where the slice implements it; disagreements between
//! versions and Oliver's chosen resolutions are recorded in
//! docs/FEATURE-MATRIX.md, docs/TEXTILE-INLINE-CODE.md, and
//! docs/TEXTILE-EMPHASIS.md.
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
//! - `@code@` is recognized only within one line, with the conservative
//!   whitespace/punctuation boundary contract in docs/TEXTILE-INLINE-CODE.md.
//!   Code content is an opaque, verbatim `.code_span` payload.
//! - `_x_`/`*x*` and their doubled forms are recognized within one line using
//!   the boundary, nesting, and shared-IR contract in
//!   docs/TEXTILE-EMPHASIS.md; invalid intraword/crossing/long-run shapes stay
//!   literal.
//! - Paragraph content is preserved verbatim (only the marker's separator
//!   whitespace is consumed).
//! - `h0.` and `h7.`+ are not headings; they remain paragraph text.

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");
const diagnostic = @import("diagnostic.zig");
const unicode = @import("unicode.zig");

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
        try parseInlines(doc, paragraph, ref.content);
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

/// One line-local item discovered before Textile phrase matching. Delimiters
/// are kept as items so a later pass can pair them without rescanning source;
/// code spans are opaque leaves and therefore never contribute delimiter
/// items of their own.
const InlineItem = union(enum) {
    text: source.Span,
    code: CodeItem,
    delimiter: Delimiter,
};

const CodeItem = struct {
    span: source.Span,
    payload: []const u8,
};

const Delimiter = struct {
    span: source.Span,
    ch: u8,
    len: u8,
    can_open: bool,
    can_close: bool,
    match: ?usize = null,
};

/// Parses one line's inline range. Code discovery runs first and produces
/// opaque items; the remaining source is tokenized into text and one/two-byte
/// phrase delimiters, matched by an explicit stack, and emitted iteratively.
/// This keeps `@...@` precedence over `_..._`/`*...*`, permits nested
/// emphasis around code, and bounds hostile input to linear work.
fn parseInlines(doc: *document.Document, parent: *document.Node, content: source.Span) ParseError!void {
    if (content.isEmpty()) return;

    var code_items = std.ArrayList(CodeItem).empty;
    defer code_items.deinit(doc.allocator());
    try discoverCodeItems(doc, content, &code_items);

    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());

    var cursor: usize = 0;
    for (code_items.items) |code| {
        const start = @as(usize, @intCast(code.span.start - content.start));
        const end = @as(usize, @intCast(code.span.end - content.start));
        try scanPlainItems(doc, content, cursor, start, &items);
        try items.append(doc.allocator(), .{ .code = code });
        cursor = end;
    }
    try scanPlainItems(doc, content, cursor, content.len(), &items);

    try matchTextileDelimiters(&items, doc.allocator());
    try emitInlineItems(doc, parent, &items);
}

/// Discovers same-line `@...@` phrases with the T2 first-candidate rule. A
/// failed first closer invalidates the old opener and may seed the next one;
/// neither branch ever scans backwards or rescans a suffix.
fn discoverCodeItems(
    doc: *document.Document,
    content: source.Span,
    out: *std.ArrayList(CodeItem),
) ParseError!void {
    const bytes = doc.text(content);
    var opener: ?usize = null;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '@') continue;

        if (opener) |open| {
            if (canCloseCode(bytes, open, i)) {
                const whole = subSpan(content, open, i + 1);
                const payload_span = subSpan(content, open + 1, i);
                const payload = try doc.allocator().dupe(u8, doc.text(payload_span));
                try out.append(doc.allocator(), .{ .span = whole, .payload = payload });
                opener = null;
                continue;
            }

            // Only the first following at-sign is a closer candidate. If it
            // fails, this byte may independently seed the next candidate.
            opener = if (canOpenCode(bytes, i)) i else null;
            continue;
        }

        if (canOpenCode(bytes, i)) opener = i;
    }
}

/// Tokenizes a non-code source segment. Runs longer than two bytes, and
/// delimiter-looking bytes that fail the boundary contract, stay ordinary
/// text; this deliberately leaves `***x***` literal until a later milestone
/// chooses a three-byte combined-emphasis grammar.
fn scanPlainItems(
    doc: *document.Document,
    content: source.Span,
    start: usize,
    end: usize,
    out: *std.ArrayList(InlineItem),
) ParseError!void {
    if (start >= end) return;
    const bytes = doc.text(content);
    var text_start = start;
    var i = start;
    while (i < end) {
        const ch = bytes[i];
        if (ch != '*' and ch != '_') {
            i += 1;
            continue;
        }

        var run_end = i + 1;
        while (run_end < end and bytes[run_end] == ch) : (run_end += 1) {}
        const run_len = run_end - i;
        if ((run_len == 1 or run_len == 2) and
            (canOpenEmphasis(bytes, i, run_end) or canCloseEmphasis(bytes, i, run_end)))
        {
            if (text_start < i) {
                try out.append(doc.allocator(), .{ .text = subSpan(content, text_start, i) });
            }
            try out.append(doc.allocator(), .{ .delimiter = .{
                .span = subSpan(content, i, run_end),
                .ch = ch,
                .len = @intCast(run_len),
                .can_open = canOpenEmphasis(bytes, i, run_end),
                .can_close = canCloseEmphasis(bytes, i, run_end),
            } });
            text_start = run_end;
            i = run_end;
            continue;
        }
        i = run_end;
    }

    if (text_start < end) {
        try out.append(doc.allocator(), .{ .text = subSpan(content, text_start, end) });
    }
}

/// A Textile phrase operator must be outside a word and must touch content on
/// its inner side. Unicode punctuation/symbols count as boundaries, matching
/// the phrase-boundary guidance in Movable Type Textile 2.
fn canOpenEmphasis(bytes: []const u8, start: usize, end: usize) bool {
    if (end >= bytes.len) return false;
    const next = unicode.decode(bytes, end) orelse return false;
    if (unicode.isWhitespace(next)) return false;
    if (start == 0) return true;
    const previous = unicode.decodePrev(bytes, start) orelse return false;
    return isPhraseBoundary(previous);
}

fn canCloseEmphasis(bytes: []const u8, start: usize, end: usize) bool {
    if (start == 0) return false;
    const previous = unicode.decodePrev(bytes, start) orelse return false;
    if (unicode.isWhitespace(previous)) return false;
    if (end == bytes.len) return true;
    const next = unicode.decode(bytes, end) orelse return false;
    return isPhraseBoundary(next);
}

fn isPhraseBoundary(cp: u21) bool {
    return unicode.isWhitespace(cp) or unicode.isPunctuation(cp);
}

/// Pairs only the topmost compatible delimiter. That stack discipline keeps
/// nesting deterministic and avoids the quadratic backward searches that an
/// unmatched alternating-marker storm would otherwise trigger. The source
/// documentation does not specify crossing or mixed-length runs, so those
/// near-misses remain literal.
fn matchTextileDelimiters(items: *std.ArrayList(InlineItem), allocator: std.mem.Allocator) !void {
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(allocator);

    for (items.items, 0..) |*item, index| {
        if (item.* != .delimiter) continue;
        const delimiter = &item.delimiter;
        var consumed_as_closer = false;
        if (delimiter.can_close and stack.items.len > 0) {
            const opener_index = stack.items[stack.items.len - 1];
            const opener = &items.items[opener_index].delimiter;
            if (opener.ch == delimiter.ch and opener.len == delimiter.len and
                opener.span.end < delimiter.span.start)
            {
                opener.match = index;
                delimiter.match = opener_index;
                _ = stack.pop();
                consumed_as_closer = true;
            }
        }
        if (!consumed_as_closer and delimiter.can_open) {
            try stack.append(allocator, index);
        }
    }
}

const EmitFrame = struct {
    parent: *document.Node,
    start: usize,
    end: usize,
    next: usize,
};

/// Emits matched delimiter pairs without recursive calls. A matched `*` (or
/// `**`) becomes `.strong`; `_` (or `__`) becomes `.emphasis`. The doubled
/// spellings are mapped to the shared semantic IR rather than inventing
/// separate `<b>`/`<i>` tags; this is the explicit Oliver convergence choice.
fn emitInlineItems(
    doc: *document.Document,
    parent: *document.Node,
    items: *const std.ArrayList(InlineItem),
) ParseError!void {
    var frames = std.ArrayList(EmitFrame).empty;
    defer frames.deinit(doc.allocator());
    try frames.append(doc.allocator(), .{ .parent = parent, .start = 0, .end = items.items.len, .next = 0 });

    while (frames.items.len > 0) {
        const frame_index = frames.items.len - 1;
        if (frames.items[frame_index].next >= frames.items[frame_index].end) {
            _ = frames.pop();
            continue;
        }

        const item_index = frames.items[frame_index].next;
        frames.items[frame_index].next += 1;
        switch (items.items[item_index]) {
            .text => |span| try emitText(doc, frames.items[frame_index].parent, span),
            .code => |code| {
                const node = try doc.createNode(.code_span, code.span, .{ .code_span = code.payload });
                try doc.appendChild(frames.items[frame_index].parent, node);
            },
            .delimiter => |delimiter| {
                if (delimiter.match) |close_index| {
                    if (close_index > item_index and close_index < frames.items[frame_index].end) {
                        const close = items.items[close_index].delimiter;
                        const tag: document.Tag = if (delimiter.ch == '_') .emphasis else .strong;
                        const node = try doc.createNode(tag, .{
                            .start = delimiter.span.start,
                            .end = close.span.end,
                        }, .none);
                        try doc.appendChild(frames.items[frame_index].parent, node);
                        frames.items[frame_index].next = close_index + 1;
                        try frames.append(doc.allocator(), .{
                            .parent = node,
                            .start = item_index + 1,
                            .end = close_index,
                            .next = item_index + 1,
                        });
                        continue;
                    }
                }
                try emitText(doc, frames.items[frame_index].parent, delimiter.span);
            },
        }
    }
}

fn emitText(doc: *document.Document, parent: *document.Node, span: source.Span) ParseError!void {
    if (span.isEmpty()) return;
    const node = try doc.createNode(.text, span, .{ .text = doc.text(span) });
    try doc.appendChild(parent, node);
}

fn subSpan(outer: source.Span, start: usize, end: usize) source.Span {
    std.debug.assert(start <= end);
    std.debug.assert(end <= outer.len());
    return .{
        .start = outer.start + @as(u32, @intCast(start)),
        .end = outer.start + @as(u32, @intCast(end)),
    };
}

fn canOpenCode(bytes: []const u8, i: usize) bool {
    std.debug.assert(i < bytes.len and bytes[i] == '@');
    if (i > 0 and bytes[i - 1] == '@') return false;
    if (!isInlineBoundaryBefore(bytes, i)) return false;
    if (i + 1 >= bytes.len or bytes[i + 1] == '@') return false;
    if (unicode.decode(bytes, i + 1)) |next| {
        if (unicode.isWhitespace(next)) return false;
    }
    return true;
}

fn canCloseCode(bytes: []const u8, opener: usize, i: usize) bool {
    std.debug.assert(opener < i and bytes[opener] == '@' and bytes[i] == '@');
    if (i == opener + 1 or bytes[i - 1] == '@') return false;
    if (i + 1 < bytes.len and bytes[i + 1] == '@') return false;
    if (unicode.decodePrev(bytes, i)) |previous| {
        if (unicode.isWhitespace(previous)) return false;
    }
    return isInlineBoundaryAfter(bytes, i + 1);
}

fn isInlineBoundaryBefore(bytes: []const u8, i: usize) bool {
    if (i == 0) return true;
    const previous = unicode.decodePrev(bytes, i) orelse return false;
    return unicode.isWhitespace(previous) or unicode.isPunctuation(previous);
}

fn isInlineBoundaryAfter(bytes: []const u8, i: usize) bool {
    if (i == bytes.len) return true;
    const next = unicode.decode(bytes, i) orelse return false;
    return unicode.isWhitespace(next) or unicode.isPunctuation(next);
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

test "textile: inline code has exact spans and an opaque owned payload" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "pre @café<&@ post", .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 3), p.children.items.len);

    try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 4 }, p.children.items[0].span);
    try std.testing.expectEqualStrings("pre ", p.children.items[0].data.text);

    const code = p.children.items[1];
    try std.testing.expectEqual(document.Tag.code_span, code.tag);
    try std.testing.expectEqual(source.Span{ .start = 4, .end = 13 }, code.span);
    try std.testing.expectEqualStrings("café<&", code.data.code_span);
    try std.testing.expectEqual(@as(usize, 0), code.children.items.len);
    try std.testing.expect(code.data.code_span.ptr != result.document.src.bytes[5..12].ptr);

    try std.testing.expectEqual(document.Tag.text, p.children.items[2].tag);
    try std.testing.expectEqual(source.Span{ .start = 13, .end = 18 }, p.children.items[2].span);
    try std.testing.expectEqualStrings(" post", p.children.items[2].data.text);
}

test "textile: headings and quoted paragraphs share the inline code scanner" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "h2. @head@\nbq. @quote@", .textile, .{});
    defer result.deinit();

    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    const heading = root.children.items[0];
    try std.testing.expectEqual(document.Tag.heading, heading.tag);
    try std.testing.expectEqual(@as(u8, 2), heading.data.heading);
    try std.testing.expectEqual(@as(usize, 1), heading.children.items.len);
    try std.testing.expectEqual(document.Tag.code_span, heading.children.items[0].tag);
    try std.testing.expectEqual(source.Span{ .start = 4, .end = 10 }, heading.children.items[0].span);
    try std.testing.expectEqualStrings("head", heading.children.items[0].data.code_span);

    const quote = root.children.items[1];
    try std.testing.expectEqual(document.Tag.block_quote, quote.tag);
    const paragraph = quote.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), paragraph.children.items.len);
    try std.testing.expectEqual(document.Tag.code_span, paragraph.children.items[0].tag);
    try std.testing.expectEqual(source.Span{ .start = 15, .end = 22 }, paragraph.children.items[0].span);
    try std.testing.expectEqualStrings("quote", paragraph.children.items[0].data.code_span);
}

test "textile: inline code never crosses a line ending" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "@open\nclose@", .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 3), p.children.items.len);
    try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 5 }, p.children.items[0].span);
    try std.testing.expectEqualStrings("@open", p.children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    try std.testing.expectEqual(source.Span{ .start = 5, .end = 6 }, p.children.items[1].span);
    try std.testing.expectEqual(document.Tag.text, p.children.items[2].tag);
    try std.testing.expectEqual(source.Span{ .start = 6, .end = 12 }, p.children.items[2].span);
    try std.testing.expectEqualStrings("close@", p.children.items[2].data.text);
}

test "textile: matched and near-miss at-sign storms stay deterministic" {
    const oliver = @import("oliver.zig");
    const count = 10_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    try expected.appendSlice(std.testing.allocator, "<p>");
    for (0..count) |i| {
        if (i % 2 == 0) {
            try input.appendSlice(std.testing.allocator, "@ok@ ");
            try expected.appendSlice(std.testing.allocator, "<code>ok</code> ");
        } else {
            // The first possible closer is intraword on its right, so this
            // deliberately malformed pair stays literal without a rescan.
            try input.appendSlice(std.testing.allocator, "@bad@word ");
            try expected.appendSlice(std.testing.allocator, "@bad@word ");
        }
    }
    try expected.appendSlice(std.testing.allocator, "</p>\n");

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    var code_count: usize = 0;
    for (p.children.items) |child| {
        if (child.tag == .code_span) code_count += 1;
    }
    try std.testing.expectEqual(@as(usize, count / 2), code_count);

    var first_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_writer.deinit();
    try oliver.html.render(std.testing.allocator, &first_writer.writer, &result.document, .{});
    var first = first_writer.toArrayList();
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected.items, first.items);

    var second_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second_writer.deinit();
    try oliver.html.render(std.testing.allocator, &second_writer.writer, &result.document, .{});
    var second = second_writer.toArrayList();
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.items, second.items);
}

test "textile: emphasis and strong nesting use shared semantic tags" {
    const oliver = @import("oliver.zig");
    const input = "Textile is *_way_* cool. I **really** __know__.";
    var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 7), p.children.items.len);
    try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try std.testing.expectEqual(document.Tag.strong, p.children.items[1].tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items[1].children.items.len);
    try std.testing.expectEqual(document.Tag.emphasis, p.children.items[1].children.items[0].tag);
    try std.testing.expectEqualStrings("way", p.children.items[1].children.items[0].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.strong, p.children.items[3].tag);
    try std.testing.expectEqualStrings("really", p.children.items[3].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.emphasis, p.children.items[5].tag);
    try std.testing.expectEqualStrings("know", p.children.items[5].children.items[0].data.text);

    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try oliver.html.render(std.testing.allocator, &writer.writer, &result.document, .{});
    var rendered = writer.toArrayList();
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<p>Textile is <strong><em>way</em></strong> cool. I <strong>really</strong> <em>know</em>.</p>\n",
        rendered.items,
    );
}

test "textile: emphasis boundaries reject intraword near misses" {
    const oliver = @import("oliver.zig");
    const input = "way c*oo*l and foo_bar_baz and _yes_ *ok*.";
    var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
    defer result.deinit();

    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try oliver.html.render(std.testing.allocator, &writer.writer, &result.document, .{});
    var rendered = writer.toArrayList();
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<p>way c*oo*l and foo_bar_baz and <em>yes</em> <strong>ok</strong>.</p>\n",
        rendered.items,
    );
}

test "textile: emphasis spans are exact and code content is opaque" {
    const oliver = @import("oliver.zig");
    const input = "a *_é_* @*raw* & <@ z";
    var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    const outer = p.children.items[1];
    try std.testing.expectEqual(document.Tag.strong, outer.tag);
    try std.testing.expectEqualStrings("*_é_*", input[outer.span.start..outer.span.end]);
    const inner = outer.children.items[0];
    try std.testing.expectEqual(document.Tag.emphasis, inner.tag);
    try std.testing.expectEqualStrings("_é_", input[inner.span.start..inner.span.end]);
    try std.testing.expectEqualStrings("é", inner.children.items[0].data.text);

    const code = p.children.items[3];
    try std.testing.expectEqual(document.Tag.code_span, code.tag);
    try std.testing.expectEqualStrings("@*raw* & <@", input[code.span.start..code.span.end]);
    try std.testing.expectEqualStrings("*raw* & <", code.data.code_span);
    try std.testing.expect(code.data.code_span.ptr != input[code.span.start + 1 .. code.span.end - 1].ptr);
    try std.testing.expectEqualStrings(" z", p.children.items[4].data.text);
}

test "textile: emphasis does not cross line-local hard breaks" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "_open\nclose_", .textile, .{});
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(document.Tag.hard_break, p.children.items[2].tag);
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try oliver.html.render(std.testing.allocator, &writer.writer, &result.document, .{});
    var rendered = writer.toArrayList();
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<p>_open<br />\nclose_</p>\n", rendered.items);
}

test "textile: emphasis marker storms remain iterative and deterministic" {
    const oliver = @import("oliver.zig");
    const count = 10_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    for (0..count) |i| {
        if (i % 2 == 0) {
            try input.appendSlice(std.testing.allocator, "_ok_ *yes* ");
        } else {
            // Intraword and three-byte runs remain literal by contract.
            try input.appendSlice(std.testing.allocator, "c*oo*l ***x*** ");
        }
    }

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
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

    // Alternating openers/closers exercise deeply nested mixed emphasis while
    // the explicit emit frame stack keeps parser call-stack depth constant.
    const depth = 2_000;
    var nested_input = std.ArrayList(u8).empty;
    defer nested_input.deinit(std.testing.allocator);
    for (0..depth) |_| try nested_input.appendSlice(std.testing.allocator, "*_");
    try nested_input.appendSlice(std.testing.allocator, "x");
    for (0..depth) |_| try nested_input.appendSlice(std.testing.allocator, "_*");
    var nested = try oliver.parse(std.testing.allocator, nested_input.items, .textile, .{});
    defer nested.deinit();
    var nested_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer nested_writer.deinit();
    try oliver.html.render(std.testing.allocator, &nested_writer.writer, &nested.document, .{});
    var nested_output = nested_writer.toArrayList();
    defer nested_output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, nested_output.items, "<p><strong><em>"));
    try std.testing.expect(std.mem.endsWith(u8, nested_output.items, "</em></strong></p>\n"));
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
