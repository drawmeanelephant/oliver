//! Textile frontend.
//!
//! Blocks: paragraphs, `h1.`–`h6.` headings, single-period `bq.` block
//! quotes, and `*`/`#` lists with marker-depth nesting. Inlines: plain text,
//! hard line breaks, same-line `@code@` phrases, the phrase-modifier family
//! (`*strong*`, `_emphasis_`, `**bold**`, `__italic__`, `-deleted-`,
//! `+inserted+`, `^superscript^`, `~subscript~`, `%span%`), `"text":url`
//! links (with `(title)`), and `!url!` images (with `(alt)` and the
//! `!url!:href` link attachment).
//! Behavior is chosen from the published user-facing Textile documentation
//! (Hobix reference; Movable Type "Textile 2 Syntax"; Textile Markup Language
//! Documentation) where the slice implements it; disagreements between
//! versions and Oliver's chosen resolutions are recorded in
//! docs/FEATURE-MATRIX.md and docs/TEXTILE-INLINE-CODE.md and the parity
//! audit docs/TEXTILE-PARITY.md.
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
//! - Phrase modifiers, links, and images use the same boundary contract and
//!   are recognized within one line; phrase content is scanned for nested
//!   phrases, while link display text and image src/alt are opaque plain
//!   text (docs/TEXTILE-PARITY.md §4).
//! - Paragraph content is preserved verbatim (only the marker's separator
//!   whitespace is consumed).
//! - `h0.` and `h7.`+ are not headings; they remain paragraph text.
//! - A list item is a single line: `*` (bullet) or `#` (ordered) markers,
//!   one per nesting level, followed by a space or tab. Consecutive marker
//!   lines compose a tree of tight lists; a blank line, a block signature,
//!   or a non-marker text line closes all open lists (docs/TEXTILE-PARITY.md
//!   §6).

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
    var lists = std.ArrayList(ListEntry).empty;
    defer lists.deinit(doc.allocator());
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            try closeBlock(doc, &block);
            closeLists(&lists);
            continue;
        }
        if (tryHeading(line)) |heading| {
            try closeBlock(doc, &block);
            closeLists(&lists);
            try emitHeading(doc, line, heading);
            continue;
        }
        if (tryParagraphMarker(line)) |content| {
            try closeBlock(doc, &block);
            closeLists(&lists);
            try appendBlockContent(doc, &block, .paragraph, content, line.terminatorSpan());
            continue;
        }
        if (tryBlockQuoteMarker(line)) |content| {
            try closeBlock(doc, &block);
            closeLists(&lists);
            try appendBlockContent(doc, &block, .block_quote, content, line.terminatorSpan());
            continue;
        }
        if (tryListMarker(line)) |lm| {
            try closeBlock(doc, &block);
            try appendListItem(doc, &lists, lm);
            continue;
        }
        // A non-marker text line closes the list tree: list items are single
        // lines, so an unmarked line is a fresh paragraph (docs/TEXTILE-PARITY.md
        // §6, chosen behavior).
        if (lists.items.len > 0) closeLists(&lists);
        const kind: BlockKind = if (block) |active| active.kind else .paragraph;
        try appendBlockContent(doc, &block, kind, line.contentSpan(), line.terminatorSpan());
    }
    try closeBlock(doc, &block);
    closeLists(&lists);
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

/// One open list level of a Textile list tree. The stack is ordered by
/// ascending depth (index 0 is depth 1). A new marker line reconciles the
/// stack to its own depth and marker character, then appends its item.
const ListEntry = struct {
    depth: u32,
    /// `*` (bullet) or `#` (ordered).
    marker: u8,
    list: *document.Node,
    item: *document.Node,
};

const ListMarker = struct {
    depth: u32,
    marker: u8,
    content: source.Span,
};

/// Recognizes a list item line: one or more consecutive `*` or `#` markers
/// followed by a space or tab. A mixed marker run (`*#`) or a run not
/// followed by space/tab is ordinary text.
fn tryListMarker(line: source.Line) ?ListMarker {
    const t = line.text;
    if (t.len < 2) return null;
    const marker = t[0];
    if (marker != '*' and marker != '#') return null;
    var i: usize = 0;
    while (i < t.len and t[i] == marker) : (i += 1) {}
    if (i == t.len or (t[i] != ' ' and t[i] != '\t')) return null;
    var j = i;
    while (j < t.len and (t[j] == ' ' or t[j] == '\t')) : (j += 1) {}
    return .{
        .depth = @intCast(i),
        .marker = marker,
        .content = .{
            .start = @intCast(line.start + j),
            .end = @intCast(line.content_end),
        },
    };
}

/// Reconciles the open list stack to `lm` and appends its item. Lists deeper
/// than `lm.depth` close; a same-depth list with a different marker closes
/// and a sibling list opens; missing intermediate depths open empty items.
/// The item's content lives in the deepest new item's paragraph.
fn appendListItem(doc: *document.Document, lists: *std.ArrayList(ListEntry), lm: ListMarker) ParseError!void {
    while (lists.items.len > 0 and lists.items[lists.items.len - 1].depth > lm.depth) {
        _ = lists.pop();
    }
    if (lists.items.len > 0 and lists.items[lists.items.len - 1].depth == lm.depth) {
        const top = &lists.items[lists.items.len - 1];
        if (top.marker == lm.marker) {
            try appendSiblingItem(doc, lists, lm);
            return;
        }
        _ = lists.pop();
    }

    var depth: u32 = if (lists.items.len > 0) lists.items[lists.items.len - 1].depth else 0;
    while (depth < lm.depth) {
        depth += 1;
        const parent = if (depth == 1) doc.root else lists.items[lists.items.len - 1].item;
        const list = try doc.createNode(.list, lm.content, .{
            .list = .{
                .kind = if (lm.marker == '#') .ordered else .bullet,
                .bullet = if (lm.marker == '*') '*' else 0,
                .delimiter = if (lm.marker == '#') '.' else 0,
                .start = 1,
                .loose = false,
            },
        });
        try doc.appendChild(parent, list);
        const item = try doc.createNode(.list_item, lm.content, .none);
        try doc.appendChild(list, item);
        const para = try doc.createNode(.paragraph, lm.content, .none);
        try doc.appendChild(item, para);
        // Only the deepest item carries this line's content; intermediate
        // levels created by a depth jump get an empty item.
        if (depth == lm.depth) try parseInlines(doc, para, lm.content);
        try lists.append(doc.allocator(), .{ .depth = depth, .marker = lm.marker, .list = list, .item = item });
    }
}

/// Adds a sibling item to the open list at `lm.depth` (same marker char) and
/// extends the list span to cover the new item's content.
fn appendSiblingItem(doc: *document.Document, lists: *std.ArrayList(ListEntry), lm: ListMarker) ParseError!void {
    const top = &lists.items[lists.items.len - 1];
    top.list.span.end = lm.content.end;
    const item = try doc.createNode(.list_item, lm.content, .none);
    try doc.appendChild(top.list, item);
    const para = try doc.createNode(.paragraph, lm.content, .none);
    try doc.appendChild(item, para);
    try parseInlines(doc, para, lm.content);
    top.item = item;
}

/// Closes every open list. The nodes are already in the tree; only the
/// reconciliation stack is dropped.
fn closeLists(lists: *std.ArrayList(ListEntry)) void {
    lists.clearRetainingCapacity();
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

// ---------------------------------------------------------------------------
// Inline pass.
//
// One linear scan turns a line's content into a flat item list (maximal
// text runs plus atoms), then phrase delimiters are paired on a strict-LIFO
// stack, then the items are emitted into the shared model. Code spans,
// links, and images are atoms — their contents are opaque. Phrase delimiters
// nest (`*_way_*`); a closer only closes the innermost open phrase whose
// character and run length match. Each scan/emit pass visits every byte a
// bounded number of times, so even hostile delimiter storms stay linear.
// See docs/TEXTILE-INLINE-CODE.md and docs/TEXTILE-PARITY.md.
// ---------------------------------------------------------------------------

/// A half-open byte range relative to a line's content span.
const Range = struct { start: usize, end: usize };

const LinkData = struct {
    /// Full construct: opening quote through the end of the URL.
    span: Range,
    /// Display text inside the quotes (plain text, not re-scanned).
    display: Range,
    href: Range,
    title: ?Range,
};

const ImageData = struct {
    span: Range,
    src: Range,
    alt: ?Range,
    link_href: ?Range,
};

const InlineItem = union(enum) {
    /// Maximal text run between constructs (relative offsets into the line).
    text: Range,
    /// A matched `@code@` span with its verbatim arena-owned payload.
    code: struct { span: Range, payload: []const u8 },
    /// A phrase delimiter run. `pair` is the item index of the matching
    /// closer (on the opener side) or opener (on the closer side); an
    /// unmatched run stays literal text.
    phrase: struct {
        pos: usize,
        len: u8,
        char: u8,
        tag: document.Tag,
        is_open: bool,
        is_close: bool,
        pair: ?usize,
    },
    link: LinkData,
    image: ImageData,
};

const PhraseOp = struct {
    char: u8,
    len: u8,
    tag: document.Tag,
};

/// The phrase-modifier family both references document: single `*`/`_` are
/// strong/emphasis, doubled `**`/`__` are bold/italic, and `-`, `+`, `^`,
/// `~`, `%` are del/ins/sup/sub/span. Textile 2's `++`/`--` (big/small) are
/// deliberately deferred (docs/FEATURE-MATRIX.md). Runs longer than the
/// recognized lengths stay literal.
fn phraseOpFor(bytes: []const u8, i: usize) ?PhraseOp {
    const c = bytes[i];
    if (c != '*' and c != '_' and c != '-' and c != '+' and c != '^' and c != '~' and c != '%') return null;
    var j = i + 1;
    while (j < bytes.len and bytes[j] == c) : (j += 1) {}
    const run = j - i;
    return switch (c) {
        '*' => if (run == 1) .{ .char = '*', .len = 1, .tag = .strong } else if (run == 2) .{ .char = '*', .len = 2, .tag = .bold } else null,
        '_' => if (run == 1) .{ .char = '_', .len = 1, .tag = .emphasis } else if (run == 2) .{ .char = '_', .len = 2, .tag = .italic } else null,
        '-' => if (run == 1) .{ .char = '-', .len = 1, .tag = .deleted } else null,
        '+' => if (run == 1) .{ .char = '+', .len = 1, .tag = .inserted } else null,
        '^' => if (run == 1) .{ .char = '^', .len = 1, .tag = .superscript } else null,
        '~' => if (run == 1) .{ .char = '~', .len = 1, .tag = .subscript } else null,
        '%' => if (run == 1) .{ .char = '%', .len = 1, .tag = .span } else null,
        else => null,
    };
}

/// Phase 1: scan one line's content into items. Code spans keep the exact
/// first-following-at-sign, close-once contract of docs/TEXTILE-INLINE-CODE.md
/// §2. Links, images, and phrase delimiters are discovered in the same pass.
/// Lookaheads for links/images only reach the next `"`/`!` (or a URL's
/// whitespace), so segments scanned by failing lookaheads are disjoint and
/// the pass stays linear.
fn scanLineItems(doc: *document.Document, items: *std.ArrayList(InlineItem), content: source.Span) ParseError!void {
    const bytes = doc.text(content);
    var run_start: usize = 0;
    var code_opener: ?usize = null;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '@') {
            if (code_opener) |open| {
                if (canCloseCode(bytes, open, i)) {
                    try appendTextItem(doc.allocator(), items, run_start, open);
                    const payload = try doc.allocator().dupe(u8, doc.text(subSpan(content, open + 1, i)));
                    try items.append(doc.allocator(), .{ .code = .{
                        .span = .{ .start = open, .end = i + 1 },
                        .payload = payload,
                    } });
                    run_start = i + 1;
                    code_opener = null;
                } else {
                    // Only the first following at-sign can close this opener.
                    // If it cannot, preserve the old candidate literally and
                    // let this byte act as a fresh opener only when it
                    // qualifies on its own.
                    code_opener = if (canOpenCode(bytes, i)) i else null;
                }
            } else if (canOpenCode(bytes, i)) {
                code_opener = i;
            }
            i += 1;
            continue;
        }
        // While a code opener is pending, every byte until the next at-sign
        // is candidate code content: phrases, links, and images inside are
        // opaque (docs/TEXTILE-INLINE-CODE.md §3, "opaque leaf").
        if (code_opener == null) {
            if (b == '"') {
                if (scanLink(bytes, i)) |link| {
                    try appendTextItem(doc.allocator(), items, run_start, i);
                    try items.append(doc.allocator(), .{ .link = link });
                    run_start = link.span.end;
                    i = run_start;
                    continue;
                }
                i += 1;
                continue;
            }
            if (b == '!') {
                if (scanImage(bytes, i)) |image| {
                    try appendTextItem(doc.allocator(), items, run_start, i);
                    try items.append(doc.allocator(), .{ .image = image });
                    run_start = image.span.end;
                    i = run_start;
                    continue;
                }
                i += 1;
                continue;
            }
            if (phraseOpFor(bytes, i)) |op| {
                const open_ok = canOpenPhrase(bytes, i, op.len);
                const close_ok = canClosePhrase(bytes, i, op.len);
                if (open_ok or close_ok) {
                    try appendTextItem(doc.allocator(), items, run_start, i);
                    try items.append(doc.allocator(), .{ .phrase = .{
                        .pos = i,
                        .len = op.len,
                        .char = op.char,
                        .tag = op.tag,
                        .is_open = open_ok,
                        .is_close = close_ok,
                        .pair = null,
                    } });
                    i += op.len;
                    run_start = i;
                    continue;
                }
                // A run that qualifies neither way is literal. Runs longer
                // than any documented operator stay whole and literal: a
                // `***` is never split into a literal `*` plus a bold `**`
                // (conservative; docs/TEXTILE-PARITY.md §4.1).
                i += op.len;
                continue;
            } else if (b == '*' or b == '_' or b == '-' or b == '+' or b == '^' or b == '~' or b == '%') {
                // Long runs (3+ for `*`/`_`, 2+ for the rest) stay entirely
                // literal; skip the whole run so it cannot reseed a shorter
                // operator from inside itself.
                var j = i + 1;
                while (j < bytes.len and bytes[j] == b) : (j += 1) {}
                i = j;
                continue;
            }
        }
        i += 1;
    }
    try appendTextItem(doc.allocator(), items, run_start, bytes.len);
}

fn appendTextItem(allocator: std.mem.Allocator, items: *std.ArrayList(InlineItem), start: usize, end: usize) ParseError!void {
    if (start >= end) return;
    try items.append(allocator, .{ .text = .{ .start = start, .end = end } });
}

/// Recognizes `"text":url` and `"text (title)":url` (Textile 2 links).
/// The display text must be non-empty and not start/end with whitespace; the
/// URL runs to the first whitespace, with common trailing sentence
/// punctuation excluded (Hobix: "the link won't include any trailing
/// punctuation"). A title is the parenthesized suffix of the display text
/// when preceded by a space. Returns null (the `"` stays literal text) for
/// any shape the references do not define; see docs/TEXTILE-PARITY.md §5.
fn scanLink(bytes: []const u8, i: usize) ?LinkData {
    if (!isInlineBoundaryBefore(bytes, i)) return null;
    const close = std.mem.indexOfScalarPos(u8, bytes, i + 1, '"') orelse return null;
    if (close == i + 1) return null;
    if (isWhitespaceByte(bytes[i + 1]) or isWhitespaceByte(bytes[close - 1])) return null;
    if (close + 1 >= bytes.len or bytes[close + 1] != ':') return null;
    const url_start = close + 2;
    if (url_start >= bytes.len) return null;
    var url_end = url_start;
    while (url_end < bytes.len and !isUrlStop(bytes[url_end])) : (url_end += 1) {}
    while (url_end > url_start and isLinkTrailingPunct(bytes[url_end - 1])) : (url_end -= 1) {}
    if (url_end == url_start) return null;

    var display_end = close;
    var title: ?Range = null;
    if (bytes[close - 1] == ')') {
        if (lastIndexOfByte(bytes[i + 1 .. close], '(')) |p| {
            const open = i + 1 + p;
            // The title is the parenthesized suffix; the `)` at `close - 1`
            // is its closing paren, so the range ends before it.
            if (open > i + 1 and open + 1 < close - 1 and bytes[open - 1] == ' ') {
                title = .{ .start = open + 1, .end = close - 1 };
                display_end = open - 1;
            }
        }
    }
    return .{
        .span = .{ .start = i, .end = url_end },
        .display = .{ .start = i + 1, .end = display_end },
        .href = .{ .start = url_start, .end = url_end },
        .title = title,
    };
}

/// Recognizes `!url!`, `!url(alt)!` (Hobix) / `!url (alt)!` (Textile 2), and
/// the `!url!:href` link attachment. The src must be non-empty, contain no
/// whitespace, and not begin with a documented image modifier (`<`, `>`, `-`,
/// `^`, `~`, `{`, `(`, `)`) — modifier/sizing forms stay literal until their
/// milestone (docs/FEATURE-MATRIX.md). A parenthesized suffix before the
/// closing `!` is the alt, which doubles as the title (Hobix example). The
/// `!` closer requires a whitespace/punctuation boundary after, so `!a.png!b`
/// stays literal. See docs/TEXTILE-PARITY.md §5.
fn scanImage(bytes: []const u8, i: usize) ?ImageData {
    if (!isInlineBoundaryBefore(bytes, i)) return null;
    const close = std.mem.indexOfScalarPos(u8, bytes, i + 1, '!') orelse return null;
    if (close == i + 1) return null;

    var src_end = close;
    var alt: ?Range = null;
    if (bytes[close - 1] == ')') {
        if (lastIndexOfByte(bytes[i + 1 .. close], '(')) |p| {
            const open = i + 1 + p;
            // The alt is the parenthesized suffix; the `)` at `close - 1`
            // is its closing paren, so the range ends before it.
            if (open > i + 1 and open + 1 < close - 1) {
                alt = .{ .start = open + 1, .end = close - 1 };
                src_end = open;
                while (src_end > i + 1 and isWhitespaceByte(bytes[src_end - 1])) src_end -= 1;
            }
        }
    }
    if (src_end == i + 1 or isDeferredImageModifier(bytes[i + 1])) return null;
    var k = i + 1;
    while (k < src_end) : (k += 1) {
        if (isWhitespaceByte(bytes[k])) return null;
    }

    var link_href: ?Range = null;
    if (close + 1 < bytes.len and bytes[close + 1] == ':') {
        const url_start = close + 2;
        if (url_start < bytes.len) {
            var url_end = url_start;
            while (url_end < bytes.len and !isUrlStop(bytes[url_end])) : (url_end += 1) {}
            while (url_end > url_start and isLinkTrailingPunct(bytes[url_end - 1])) : (url_end -= 1) {}
            if (url_end > url_start) link_href = .{ .start = url_start, .end = url_end };
        }
    }
    const span_end = if (link_href) |h| h.end else close + 1;
    if (!isInlineBoundaryAfter(bytes, span_end)) return null;

    return .{
        .span = .{ .start = i, .end = span_end },
        .src = .{ .start = i + 1, .end = src_end },
        .alt = alt,
        .link_href = link_href,
    };
}

/// A phrase opener qualifies when it has a whitespace/punctuation boundary
/// before and non-whitespace content immediately after the run. A closer
/// qualifies symmetrically. The boundary contract mirrors `@code@`
/// (docs/TEXTILE-INLINE-CODE.md §2); edge-whitespace and intraword shapes
/// stay literal.
fn canOpenPhrase(bytes: []const u8, i: usize, len: usize) bool {
    if (!isInlineBoundaryBefore(bytes, i)) return false;
    if (i + len >= bytes.len) return false;
    if (unicode.decode(bytes, i + len)) |next| {
        if (unicode.isWhitespace(next)) return false;
    }
    return true;
}

fn canClosePhrase(bytes: []const u8, i: usize, len: usize) bool {
    if (i == 0) return false;
    if (unicode.decodePrev(bytes, i)) |previous| {
        if (unicode.isWhitespace(previous)) return false;
    }
    return isInlineBoundaryAfter(bytes, i + len);
}

fn isWhitespaceByte(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// Common sentence punctuation that may follow (and is therefore excluded
/// from) a Textile link/image URL (Hobix trailing-punctuation rule; Textile 2
/// "common punctuation which can reside at the end of the URL").
fn isLinkTrailingPunct(b: u8) bool {
    return switch (b) {
        '.', ',', ';', ':', '!', '?', ')', ']', '}', '\'', '"' => true,
        else => false,
    };
}

/// A URL run stops at whitespace or a closing bracket. The closing bracket
/// is Textile 2's documented bracket/brace trick — `You["gotta":url]seethis!`
/// — so the URL never swallows the `]` (or `)`/`}`) that ends it.
fn isUrlStop(b: u8) bool {
    return isWhitespaceByte(b) or b == ')' or b == ']' or b == '}';
}

/// Documented Textile image modifiers that begin the content after `!`;
/// Oliver defers them, so such images stay literal.
fn isDeferredImageModifier(b: u8) bool {
    return switch (b) {
        '<', '>', '-', '^', '~', '{', '(', ')' => true,
        else => false,
    };
}

fn lastIndexOfByte(haystack: []const u8, needle: u8) ?usize {
    var i = haystack.len;
    while (i > 0) {
        i -= 1;
        if (haystack[i] == needle) return i;
    }
    return null;
}

/// Phase 2: pair phrase openers/closers on a strict-LIFO stack. A closer
/// only matches the innermost open phrase with the same character and run
/// length (`*_way_*` nests; a different type in between leaves both literal,
/// docs/TEXTILE-PARITY.md §4.1).
fn matchPhrases(doc: *document.Document, items: *std.ArrayList(InlineItem)) ParseError!void {
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(doc.allocator());
    for (items.items, 0..) |item, idx| {
        switch (item) {
            .phrase => |p| {
                if (p.is_close) {
                    if (stack.items.len > 0) {
                        const top = stack.items[stack.items.len - 1];
                        const top_phrase = items.items[top].phrase;
                        if (top_phrase.char == p.char and top_phrase.len == p.len) {
                            items.items[top].phrase.pair = idx;
                            items.items[idx].phrase.pair = top;
                            _ = stack.pop();
                        }
                    }
                } else if (p.is_open) {
                    try stack.append(doc.allocator(), idx);
                }
            },
            else => {},
        }
    }
}

const EmitScope = struct {
    items: []const InlineItem,
    from: usize,
    to: usize,
    parent: *document.Node,
};

/// Phase 3: emit items into the model. Phrase pairs become container nodes
/// whose content is emitted into a nested scope. The work stack is explicit
/// (no recursion), so deeply nested phrases cannot overflow the call stack.
fn emitItems(doc: *document.Document, parent: *document.Node, content: source.Span, items: []const InlineItem) ParseError!void {
    var work = std.ArrayList(EmitScope).empty;
    defer work.deinit(doc.allocator());
    try work.append(doc.allocator(), .{ .items = items, .from = 0, .to = items.len, .parent = parent });
    while (work.pop()) |scope| {
        var i = scope.from;
        while (i < scope.to) {
            switch (scope.items[i]) {
                .text => |t| {
                    try emitText(doc, scope.parent, subSpan(content, t.start, t.end));
                    i += 1;
                },
                .code => |c| {
                    const node = try doc.createNode(.code_span, subSpan(content, c.span.start, c.span.end), .{ .code_span = c.payload });
                    try doc.appendChild(scope.parent, node);
                    i += 1;
                },
                .phrase => |p| {
                    if (p.pair) |j| {
                        const closer = scope.items[j].phrase;
                        const node = try doc.createNode(p.tag, subSpan(content, p.pos, closer.pos + closer.len), .none);
                        try doc.appendChild(scope.parent, node);
                        try work.append(doc.allocator(), .{ .items = items, .from = i + 1, .to = j, .parent = node });
                        i = j + 1;
                    } else {
                        try emitText(doc, scope.parent, subSpan(content, p.pos, p.pos + p.len));
                        i += 1;
                    }
                },
                .link => |l| {
                    const link = try doc.createNode(.link, subSpan(content, l.span.start, l.span.end), .{
                        .link = .{
                            .href = try doc.allocator().dupe(u8, bytesOf(doc, content, l.href)),
                            .title = if (l.title) |t| try doc.allocator().dupe(u8, bytesOf(doc, content, t)) else null,
                        },
                    });
                    try doc.appendChild(scope.parent, link);
                    const display = subSpan(content, l.display.start, l.display.end);
                    const text_node = try doc.createNode(.text, display, .{ .text = doc.text(display) });
                    try doc.appendChild(link, text_node);
                    i += 1;
                },
                .image => |im| {
                    const image = try doc.createNode(.image, subSpan(content, im.span.start, im.span.end), .{
                        .image = .{
                            .src = try doc.allocator().dupe(u8, bytesOf(doc, content, im.src)),
                            .alt = if (im.alt) |a| try doc.allocator().dupe(u8, bytesOf(doc, content, a)) else "",
                            .title = if (im.alt) |a| try doc.allocator().dupe(u8, bytesOf(doc, content, a)) else null,
                        },
                    });
                    if (im.link_href) |href| {
                        const link = try doc.createNode(.link, subSpan(content, im.span.start, im.span.end), .{
                            .link = .{ .href = try doc.allocator().dupe(u8, bytesOf(doc, content, href)), .title = null },
                        });
                        try doc.appendChild(scope.parent, link);
                        try doc.appendChild(link, image);
                    } else {
                        try doc.appendChild(scope.parent, image);
                    }
                    i += 1;
                },
            }
        }
    }
}

/// The source bytes covered by a relative range of `content`.
fn bytesOf(doc: *const document.Document, content: source.Span, range: Range) []const u8 {
    return doc.text(subSpan(content, range.start, range.end));
}

/// Parses one line's content into inline nodes under `parent`.
fn parseInlines(doc: *document.Document, parent: *document.Node, content: source.Span) ParseError!void {
    if (content.isEmpty()) return;
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    try scanLineItems(doc, &items, content);
    try matchPhrases(doc, &items);
    try emitItems(doc, parent, content, items.items);
}

fn emitText(doc: *document.Document, parent: *document.Node, span: source.Span) ParseError!void {
    if (span.isEmpty()) return;
    // Contiguous text in the same parent merges into one node (model
    // invariant 11): scanning artifacts like unmatched phrase delimiters
    // must not fragment the normalized model. Mirrors the Markdown engine's
    // merge rule, including the backslash exception so renderer entity
    // decoding stays escape-aware.
    if (parent.children.items.len > 0) {
        const last = parent.children.items[parent.children.items.len - 1];
        if (last.tag == .text and last.span.end == span.start and
            !(last.span.start > 0 and doc.src.bytes[last.span.start - 1] == '\\'))
        {
            last.span.end = span.end;
            last.data.text = doc.text(last.span);
            return;
        }
    }
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

test "textile: phrase modifier family tags, spans, and rendering" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        std.testing.allocator,
        "a *strong* _em_ **bold** __italic__ -del- +ins+ ^sup^ ~sub~ %span%",
        .textile,
        .{},
    );
    defer result.deinit();

    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 18), p.children.items.len);
    try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try std.testing.expectEqual(document.Tag.strong, p.children.items[1].tag);
    try std.testing.expectEqual(source.Span{ .start = 2, .end = 10 }, p.children.items[1].span);
    try std.testing.expectEqual(document.Tag.emphasis, p.children.items[3].tag);
    try std.testing.expectEqual(source.Span{ .start = 11, .end = 15 }, p.children.items[3].span);
    try std.testing.expectEqual(document.Tag.bold, p.children.items[5].tag);
    try std.testing.expectEqual(source.Span{ .start = 16, .end = 24 }, p.children.items[5].span);
    try std.testing.expectEqual(document.Tag.italic, p.children.items[7].tag);
    try std.testing.expectEqual(source.Span{ .start = 25, .end = 35 }, p.children.items[7].span);
    try std.testing.expectEqual(document.Tag.deleted, p.children.items[9].tag);
    try std.testing.expectEqual(source.Span{ .start = 36, .end = 41 }, p.children.items[9].span);
    try std.testing.expectEqual(document.Tag.inserted, p.children.items[11].tag);
    try std.testing.expectEqual(source.Span{ .start = 42, .end = 47 }, p.children.items[11].span);
    try std.testing.expectEqual(document.Tag.superscript, p.children.items[13].tag);
    try std.testing.expectEqual(source.Span{ .start = 48, .end = 53 }, p.children.items[13].span);
    try std.testing.expectEqual(document.Tag.subscript, p.children.items[15].tag);
    try std.testing.expectEqual(source.Span{ .start = 54, .end = 59 }, p.children.items[15].span);
    try std.testing.expectEqual(document.Tag.span, p.children.items[17].tag);
    try std.testing.expectEqual(source.Span{ .start = 60, .end = 66 }, p.children.items[17].span);
    // Phrase content spans and child text.
    try std.testing.expectEqualStrings("strong", p.children.items[1].children.items[0].data.text);
    try std.testing.expectEqualStrings("em", p.children.items[3].children.items[0].data.text);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<p>a <strong>strong</strong> <em>em</em> <b>bold</b> <i>italic</i> <del>del</del> <ins>ins</ins> <sup>sup</sup> <sub>sub</sub> <span>span</span></p>\n",
        out.items,
    );
}

test "textile: phrase modifiers nest and close in order" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "Textile is *_way_* cool.", .textile, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // text, strong, text
    try std.testing.expectEqual(@as(usize, 3), p.children.items.len);
    const strong = p.children.items[1];
    try std.testing.expectEqual(document.Tag.strong, strong.tag);
    try std.testing.expectEqual(@as(usize, 1), strong.children.items.len);
    try std.testing.expectEqual(document.Tag.emphasis, strong.children.items[0].tag);
    try std.testing.expectEqual(source.Span{ .start = 11, .end = 18 }, strong.span);
    try std.testing.expectEqual(source.Span{ .start = 12, .end = 17 }, strong.children.items[0].span);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<p>Textile is <strong><em>way</em></strong> cool.</p>\n", out.items);
}

test "textile: phrase modifier boundary fallbacks stay literal" {
    const oliver = @import("oliver.zig");
    const cases = [_][]const u8{
        "Textile is way c*oo*l.", // intraword (Textile 2 counterexample)
        "Text * x*", // edge whitespace after opener
        "*x *", // edge whitespace before closer
        "***triple***", // run longer than any documented operator
        "--smaller--", // Textile 2 big/small are deferred
        "a^2 + b", // intraword caret
        "50% of", // intraword percent
        "*open", // unmatched opener
    };
    for (cases) |input| {
        var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), p.children.items.len);
        try std.testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try std.testing.expectEqualStrings(input, p.children.items[0].data.text);
    }
}

test "textile: links have exact spans, hrefs, titles, and literal fallbacks" {
    const oliver = @import("oliver.zig");

    // Trailing sentence punctuation is excluded from the href (Hobix).
    {
        var result = try oliver.parse(std.testing.allocator, "I searched \"Google\":http://google.com.", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 3), p.children.items.len);
        const link = p.children.items[1];
        try std.testing.expectEqual(document.Tag.link, link.tag);
        try std.testing.expectEqual(source.Span{ .start = 11, .end = 37 }, link.span);
        try std.testing.expectEqualStrings("http://google.com", link.data.link.href);
        try std.testing.expectEqual(@as(?[]const u8, null), link.data.link.title);
        try std.testing.expectEqual(@as(usize, 1), link.children.items.len);
        try std.testing.expectEqualStrings("Google", link.children.items[0].data.text);
        try std.testing.expectEqualStrings(".", p.children.items[2].data.text);
    }
    // Parenthesized title (Textile 2).
    {
        var result = try oliver.parse(std.testing.allocator, "\"E-mail me (Please)\":mailto:someone@example.com", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const link = p.children.items[0];
        try std.testing.expectEqual(document.Tag.link, link.tag);
        try std.testing.expectEqualStrings("mailto:someone@example.com", link.data.link.href);
        try std.testing.expectEqualStrings("Please", link.data.link.title.?);
        try std.testing.expectEqualStrings("E-mail me", link.children.items[0].data.text);
    }
    // The bracket trick (Textile 2): the URL stops at the closing bracket.
    {
        var result = try oliver.parse(std.testing.allocator, "You[\"gotta\":http://example.com]seethis!", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const link = p.children.items[1];
        try std.testing.expectEqual(document.Tag.link, link.tag);
        try std.testing.expectEqualStrings("http://example.com", link.data.link.href);
        try std.testing.expectEqualStrings("gotta", link.children.items[0].data.text);
    }
    // Undefined shapes stay literal: no colon, empty display, edge whitespace.
    const literal_cases = [_][]const u8{
        "a \"no colon\" b",
        "\"\":url",
        "\" spaced \":url",
        "\"x\": ",
    };
    for (literal_cases) |input| {
        var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        var has_link = false;
        for (p.children.items) |child| {
            if (child.tag == .link) has_link = true;
        }
        try std.testing.expect(!has_link);
    }
}

test "textile: images have exact spans, alts, titles, links, and fallbacks" {
    const oliver = @import("oliver.zig");

    {
        var result = try oliver.parse(std.testing.allocator, "!https://hobix.com/sample.jpg!", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const img = p.children.items[0];
        try std.testing.expectEqual(document.Tag.image, img.tag);
        try std.testing.expectEqual(source.Span{ .start = 0, .end = 30 }, img.span);
        try std.testing.expectEqualStrings("https://hobix.com/sample.jpg", img.data.image.src);
        try std.testing.expectEqualStrings("", img.data.image.alt);
        try std.testing.expectEqual(@as(?[]const u8, null), img.data.image.title);
    }
    // Hobix: the parenthesized alt doubles as the title.
    {
        var result = try oliver.parse(std.testing.allocator, "!openwindow1.gif(Bunny.)!", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const img = p.children.items[0];
        try std.testing.expectEqualStrings("openwindow1.gif", img.data.image.src);
        try std.testing.expectEqualStrings("Bunny.", img.data.image.alt);
        try std.testing.expectEqualStrings("Bunny.", img.data.image.title.?);
    }
    // Textile 2 allows a space before the alt.
    {
        var result = try oliver.parse(std.testing.allocator, "!/path/to/image (Alt text)!", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const img = p.children.items[0];
        try std.testing.expectEqualStrings("/path/to/image", img.data.image.src);
        try std.testing.expectEqualStrings("Alt text", img.data.image.alt);
    }
    // Link attachment wraps the image in a link (Hobix).
    {
        var result = try oliver.parse(std.testing.allocator, "!openwindow1.gif!:https://hobix.com/", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const link = p.children.items[0];
        try std.testing.expectEqual(document.Tag.link, link.tag);
        try std.testing.expectEqualStrings("https://hobix.com/", link.data.link.href);
        try std.testing.expectEqual(@as(usize, 1), link.children.items.len);
        try std.testing.expectEqual(document.Tag.image, link.children.items[0].tag);
        try std.testing.expectEqualStrings("openwindow1.gif", link.children.items[0].data.image.src);
    }
    // Deferred modifier/sizing forms and malformed shapes stay literal.
    const literal_cases = [_][]const u8{
        "!>obake.gif!", // alignment modifier (deferred)
        "!-(middle).gif!", // middle-alignment modifier (deferred)
        "!a b.png!", // whitespace in src (sizing form, deferred)
        "!img.png", // no closer
        "!img.png!word", // no boundary after the closer
    };
    for (literal_cases) |input| {
        var result = try oliver.parse(std.testing.allocator, input, .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        var has_image = false;
        for (p.children.items) |child| {
            if (child.tag == .image) has_image = true;
        }
        try std.testing.expect(!has_image);
    }
}

test "textile: lists structure, nesting, and spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        std.testing.allocator,
        "* one\n* two\n** two A\n* three\n\n# first\n# second",
        .textile,
        .{},
    );
    defer result.deinit();

    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);

    const ul = root.children.items[0];
    try std.testing.expectEqual(document.Tag.list, ul.tag);
    try std.testing.expectEqual(document.ListKind.bullet, ul.data.list.kind);
    try std.testing.expect(!ul.data.list.loose);
    try std.testing.expectEqual(@as(usize, 3), ul.children.items.len);
    try std.testing.expectEqual(source.Span{ .start = 2, .end = 28 }, ul.span);

    const first = ul.children.items[0];
    try std.testing.expectEqual(document.Tag.list_item, first.tag);
    try std.testing.expectEqual(source.Span{ .start = 2, .end = 5 }, first.span);
    try std.testing.expectEqualStrings("one", first.children.items[0].children.items[0].data.text);

    // The nested `** two A` list lives inside the second item.
    const second = ul.children.items[1];
    const nested = second.children.items[1];
    try std.testing.expectEqual(document.Tag.list, nested.tag);
    try std.testing.expectEqual(@as(usize, 1), nested.children.items.len);
    try std.testing.expectEqualStrings("two A", nested.children.items[0].children.items[0].children.items[0].data.text);

    const ol = root.children.items[1];
    try std.testing.expectEqual(document.Tag.list, ol.tag);
    try std.testing.expectEqual(document.ListKind.ordered, ol.data.list.kind);
    try std.testing.expectEqual(@as(usize, 2), ol.children.items.len);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>two A</li>\n</ul>\n</li>\n<li>three</li>\n</ul>\n<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n",
        out.items,
    );
}

test "textile: list markers, signatures, and plain lines close lists" {
    const oliver = @import("oliver.zig");

    // A different marker at the same depth starts a sibling list.
    {
        var result = try oliver.parse(std.testing.allocator, "* a\n# b", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.document.root.children.items.len);
        try std.testing.expectEqual(document.Tag.list, result.document.root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.list, result.document.root.children.items[1].tag);
    }
    // A marker run without a following space/tab is ordinary text.
    {
        var result = try oliver.parse(std.testing.allocator, "*not a list\n#nope", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // A plain line closes the list; the next marker starts a new list.
    {
        var result = try oliver.parse(std.testing.allocator, "* one\nplain\n* two", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
        try std.testing.expectEqual(document.Tag.list, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
        try std.testing.expectEqual(document.Tag.list, root.children.items[2].tag);
        try std.testing.expectEqual(@as(usize, 1), root.children.items[2].children.items.len);
    }
    // A block signature closes lists too.
    {
        var result = try oliver.parse(std.testing.allocator, "* one\nh2. Two\n* three", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(document.Tag.list, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.heading, root.children.items[1].tag);
        try std.testing.expectEqual(document.Tag.list, root.children.items[2].tag);
    }
}

test "textile: phrase delimiter storm stays deterministic and linear" {
    const oliver = @import("oliver.zig");
    const count = 10_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    try expected.appendSlice(std.testing.allocator, "<p>");
    for (0..count) |i| {
        if (i % 2 == 0) {
            try input.appendSlice(std.testing.allocator, "*ok* ");
            try expected.appendSlice(std.testing.allocator, "<strong>ok</strong> ");
        } else {
            // Intraword delimiters stay literal: near-miss shape.
            try input.appendSlice(std.testing.allocator, "x*yz ");
            try expected.appendSlice(std.testing.allocator, "x*yz ");
        }
    }
    try expected.appendSlice(std.testing.allocator, "</p>\n");

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    var strong_count: usize = 0;
    for (p.children.items) |child| {
        if (child.tag == .strong) strong_count += 1;
    }
    try std.testing.expectEqual(@as(usize, count / 2), strong_count);

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

test "textile: deeply nested phrases emit iteratively" {
    const oliver = @import("oliver.zig");
    const depth = 2_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    for (0..depth) |_| try input.appendSlice(std.testing.allocator, "*a ");
    for (0..depth) |_| try input.appendSlice(std.testing.allocator, " b*");

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);
    try std.testing.expectEqual(document.Tag.strong, p.children.items[0].tag);

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
