//! Markdown frontend.
//!
//! Implemented: paragraphs, ATX headings, backslash escapes, hard and soft
//! line breaks, emphasis and strong emphasis, code spans (§6.1), and
//! inline links (§6.6). Behavior is taken from the CommonMark
//! specification (0.31.2) where the slice implements it; divergences and
//! chosen behaviors are documented in docs/FEATURE-MATRIX.md, and the
//! emphasis/strong algorithm is derived in docs/INLINE-PARSING.md.
//!
//! Code spans are discovered *before* the delimiter scan (a discovery pass
//! over the paragraph's raw content finds equal-length backtick-string
//! pairs); the scan then treats span content as opaque — no delimiters, no
//! escapes, no breaks inside — and the emit phase materializes a
//! `code_span` node with §6.1-normalized, arena-owned content. This is the
//! first delimiter-opacity rule (code-span markers are opaque to
//! delimiters; §6.1 "Code span backticks have higher precedence than any
//! other inline constructs").
//!
//! Inline links are discovered by a second pass between scan and match:
//! unescaped `[`/`]` become bracket items at scan time; the discovery pass
//! walks the item list with a bracket stack, and on each `]` tries to
//! parse an inline link `(...)` in the source that follows it. A valid
//! link splices the bracket range (plus the consumed `(...)` items) into a
//! single `link` item whose children are the link-text items; the
//! emphasis matcher then runs separately inside each link (the spec's
//! "process emphasis with the `[` opener as stack_bottom"), and brackets
//! that never form a link stay literal text. Because a link kills every
//! earlier `[` (links cannot contain links, §6.6), links are always
//! innermost-first and link text never contains another link. This is the
//! second delimiter-opacity rule (link brackets bind more tightly than
//! emphasis; `*[foo*](/uri)` is a link).
//!
//! The parser runs in two passes, matching the spec's precedence model:
//! block structure first, then inline structure. The block pass recognizes
//! paragraphs and ATX headings; everything else is a paragraph.
//!
//! The inline pass is three phases (see docs/INLINE-PARSING.md §8):
//!   scan  — one pass over each line's raw content span, producing a flat
//!           item list (text runs, delimiter runs, line breaks). Flanking is
//!           computed against the raw span, so trailing whitespace and line
//!           boundaries classify runs exactly as the spec's "beginning and
//!           end of the line count as Unicode whitespace" requires; the
//!           leading/trailing whitespace trimming happens at emission.
//!   match — a delimiter stack processes the items left to right, matching
//!           openers to closers under rules 1-12 (§6.2), with an
//!           `openers_bottom` table so matching is amortized linear.
//!   emit  — the matched structure is materialized into document nodes;
//!           consumed delimiter bytes are covered by no node, leftover
//!           delimiters become literal text, escapes split text into
//!           adjacent nodes as before.
//!
//! Paragraph whitespace policy (deliberate; see docs/FEATURE-MATRIX.md):
//! - Leading spaces/tabs are skipped (not emitted) on every line.
//! - Trailing spaces/tabs are never emitted: a trailing run with two or more
//!   spaces produces a hard break, otherwise a soft break; the whole run is
//!   consumed. An unescaped trailing backslash also produces a hard break.
//! - ATX heading content is stripped of leading/trailing spaces/tabs before
//!   inline parsing (spec §4.2); only a trailing unescaped backslash can
//!   produce a hard break inside a heading (chosen behavior, see matrix).

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");
const diagnostic = @import("diagnostic.zig");
const unicode = @import("unicode.zig");

pub const ParseError = error{OutOfMemory};

/// Parses `doc.src` as Markdown, appending block nodes under `doc.root`.
/// The caller (`oliver.parse`) guarantees `doc.src.bytes.len <=\n/// source.max_input_len`, so all offsets fit in `u32`.
pub fn parse(doc: *document.Document, diags: *std.ArrayList(diagnostic.Diagnostic)) ParseError!void {
    _ = diags;

    var lines = source.Lines.init(doc.src.bytes);
    var paragraph: ?Paragraph = null;
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            try closeParagraph(doc, &paragraph);
        } else if (tryAtxHeading(line)) |heading| {
            try closeParagraph(doc, &paragraph);
            try emitHeading(doc, line, heading);
        } else {
            try appendParagraphLine(doc, &paragraph, line);
        }
    }
    try closeParagraph(doc, &paragraph);
}

/// A paragraph under construction. `content` is the full raw line span
/// (leading and trailing whitespace included); the inline pass decides what
/// is emitted.
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

fn appendParagraphLine(doc: *document.Document, paragraph: *?Paragraph, line: source.Line) ParseError!void {
    if (paragraph.* == null) {
        paragraph.* = .{ .start = @intCast(line.start) };
    }
    try paragraph.*.?.lines.append(doc.allocator(), .{
        .content = line.contentSpan(),
        .terminator = line.terminatorSpan(),
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

    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());

    // Discovery runs before scanning: code spans may span lines, and their
    // content is opaque to the delimiter/escape/break processing.
    var contents = try doc.allocator().alloc(source.Span, lines.len);
    defer doc.allocator().free(contents);
    for (lines, 0..) |ref, i| contents[i] = ref.content;
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, contents, &spans);

    for (lines, 0..) |ref, i| {
        const end = analyzeLineEnd(doc.src.bytes, ref.content);
        const start = skipLeadingWhitespace(doc.src.bytes, ref.content);
        try scanLine(doc, &items, ref.content, .{ .start = start, .end = end.content_end }, spans.items);
        if (i + 1 < lines.len) {
            // A line ending inside a code span is span content (§6.1: "line
            // endings are converted to spaces"), never a break — hard line
            // breaks do not occur inside code spans (§6.7).
            if (!terminatorInsideCodeSpan(ref.terminator, spans.items)) {
                try items.append(doc.allocator(), .{ .brk = .{ .kind = end.kind, .span = ref.terminator } });
            }
        }
    }
    // Second discovery pass: inline links (§6.6), before emphasis matching.
    try discoverLinks(doc, &items, span.end);
    try matchInlines(doc, node, items.items);
}

/// An ATX heading recognized on a line.
const AtxHeading = struct {
    level: u8,
    /// Span of the heading's inline content after leading/trailing
    /// whitespace stripping and closing-sequence removal.
    content: source.Span,
};

/// Recognizes an ATX heading line per CommonMark §4.2: 1–6 unescaped `#`s,
/// preceded by at most three spaces of indentation, followed by spaces/tabs
/// or end of line, with an optional closing sequence of *unescaped* `#`s
/// (preceded by spaces/tabs, followed by only spaces/tabs).
///
/// Slice divergences: a tab in the leading indentation disqualifies the line
/// (full 4-space tab-stop handling is deferred); closing-sequence detection
/// handles backslash escapes (spec example 76).
fn tryAtxHeading(line: source.Line) ?AtxHeading {
    const t = line.text;
    var i: usize = 0;
    var indent: usize = 0;
    while (i < t.len and t[i] == ' ') : (i += 1) {
        indent += 1;
    }
    if (indent > 3) return null;
    if (i < t.len and t[i] == '\t') return null; // deferred: tab indentation

    var level: usize = 0;
    while (i < t.len and t[i] == '#') : (i += 1) {
        level += 1;
    }
    if (level == 0 or level > 6) return null;
    if (i < t.len and t[i] != ' ' and t[i] != '\t') return null;

    // Skip the whitespace after the opening sequence.
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}

    const content_start = i;
    var content_end = t.len;
    // §4.2: raw contents are stripped of leading and trailing spaces/tabs.
    while (content_end > content_start and
        (t[content_end - 1] == ' ' or t[content_end - 1] == '\t'))
    {
        content_end -= 1;
    }
    // Optional closing sequence: a trailing run of *unescaped* `#`s,
    // preceded by spaces/tabs (or comprising the entire content), which is
    // stripped along with the whitespace before it. A single pass: in
    // `# foo # #` only the final `#` is the closing sequence.
    if (content_end > content_start and t[content_end - 1] == '#') {
        var run_start = content_end;
        while (run_start > content_start) {
            if (t[run_start - 1] != '#') break;
            if (isEscaped(t, run_start - 1)) break;
            run_start -= 1;
        }
        if (run_start < content_end) {
            if (run_start == content_start or
                t[run_start - 1] == ' ' or t[run_start - 1] == '\t')
            {
                content_end = run_start;
                while (content_end > content_start and
                    (t[content_end - 1] == ' ' or t[content_end - 1] == '\t'))
                {
                    content_end -= 1;
                }
            }
        }
    }

    return .{
        .level = @intCast(level),
        .content = .{
            .start = @intCast(line.start + content_start),
            .end = @intCast(line.start + content_end),
        },
    };
}

fn emitHeading(doc: *document.Document, line: source.Line, heading: AtxHeading) ParseError!void {
    const node = try doc.createNode(.heading, line.contentSpan(), .{
        .heading = heading.level,
    });
    try doc.appendChild(doc.root, node);

    const content = heading.content;
    if (content.isEmpty()) return;

    // A trailing unescaped backslash at the end of an ATX heading line is a
    // hard line break inside the heading (chosen behavior, see matrix); it is
    // scanned up to, and a hard break node is appended after.
    const bytes = doc.src.bytes;
    var scan = content;
    if (bytes[scan.end - 1] == '\\' and !isEscaped(bytes, scan.end - 1)) {
        scan.end -= 1;
    }

    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, &[_]source.Span{scan}, &spans);
    try scanLine(doc, &items, scan, scan, spans.items);
    try discoverLinks(doc, &items, scan.end);
    try matchInlines(doc, node, items.items);

    if (scan.end != content.end) {
        const brk = try doc.createNode(.hard_break, .{
            .start = scan.end,
            .end = content.end,
        }, .none);
        try doc.appendChild(node, brk);
    }
}

// ---------------------------------------------------------------------------
// Inline pass: scan -> flat item list.
// ---------------------------------------------------------------------------

const BreakKind = enum { soft, hard };

const LineEnd = struct {
    kind: BreakKind,
    /// Byte offset where emitted content ends: the trailing whitespace run
    /// (and a hard-break backslash, if present) is consumed.
    content_end: u32,
};

/// Analyzes the end of a paragraph line per §6.7: a trailing run of
/// whitespace with two or more spaces is a hard break; an unescaped
/// backslash as the final character is a hard break; otherwise the break is
/// soft. Tabs in the trailing run do not trigger a hard break. The entire
/// trailing run is consumed in every case.
fn analyzeLineEnd(bytes: []const u8, span: source.Span) LineEnd {
    var end = span.end;
    var spaces: usize = 0;
    while (end > span.start and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) : (end -= 1) {
        if (bytes[end - 1] == ' ') spaces += 1;
    }
    const trailing = span.end - end;
    if (trailing == 0 and
        end > span.start and
        bytes[end - 1] == '\\' and
        !isEscaped(bytes, end - 1))
    {
        return .{ .kind = .hard, .content_end = end - 1 };
    }
    if (spaces >= 2) return .{ .kind = .hard, .content_end = end };
    return .{ .kind = .soft, .content_end = end };
}

fn skipLeadingWhitespace(bytes: []const u8, span: source.Span) u32 {
    var i = span.start;
    while (i < span.end and (bytes[i] == ' ' or bytes[i] == '\t')) : (i += 1) {}
    return i;
}

/// A transient inline item in the flat list produced by the scan phase.
/// Allocated from the document arena; dies with the document.
const InlineItem = union(enum) {
    /// A run of literal text. The span is the emitted range (leading and
    /// trailing whitespace already trimmed); escapes are resolved at emit
    /// time, so the span may include `\X` pairs.
    text: source.Span,
    /// A maximal run of unescaped `*` or `_` characters (spec §6.2).
    delimiter: DelimiterRun,
    /// A soft or hard line break between two lines of the block.
    brk: struct { kind: BreakKind, span: source.Span },
    /// A matched code span (§6.1): `span` covers the full construct
    /// (opening backtick .. closing backtick), `content` the raw bytes
    /// between the backtick strings (may span line endings). The content is
    /// opaque: no delimiters, escapes, or breaks are recognized inside it.
    code_span: struct { span: source.Span, content: source.Span },
    /// An unescaped `[` or `]` (§6.6). `[`s are potential link openers;
    /// `]`s trigger link discovery. Brackets that never become part of a
    /// link are emitted as literal text.
    bracket: struct { ch: u8, span: source.Span },
    /// A discovered inline link (§6.6): `span` covers the whole construct
    /// `[text](dest "title")`; `children` are the link-text items (never
    /// containing another link item); `dest`/`title` are raw source spans
    /// of the destination (sans `<...>`) and title content (sans
    /// delimiters), resolved for escapes at emit time.
    link: LinkItem,
};

/// A discovered inline link (§6.6). See `InlineItem.link`.
const LinkItem = struct {
    span: source.Span,
    children: std.ArrayList(InlineItem),
    dest: source.Span,
    title: ?source.Span,
};

/// The source range any item covers. Every variant carries a span; this is
/// the union-safe accessor.
fn itemSpan(item: InlineItem) source.Span {
    return switch (item) {
        .text => |s| s,
        .delimiter => |d| d.span,
        .brk => |b| b.span,
        .code_span => |c| c.span,
        .bracket => |b| b.span,
        .link => |l| l.span,
    };
}

/// Mutates the source range of any item (every variant carries a span).
fn setItemSpan(item: *InlineItem, span: source.Span) void {
    switch (item.*) {
        .text => |*s| s.* = span,
        .delimiter => |*d| d.span = span,
        .brk => |*b| b.span = span,
        .code_span => |*c| c.span = span,
        .bracket => |*b| b.span = span,
        .link => |*l| l.span = span,
    }
}

/// A code span discovered by `discoverCodeSpans`. Spans are disjoint and
/// sorted by `span.start`.
const CodeSpan = struct {
    /// Opening backtick start .. closing backtick end.
    span: source.Span,
    /// Raw bytes between the backtick strings (the content before §6.1
    /// normalization; may include line endings).
    content: source.Span,
};

/// Discovers code spans (§6.1) over the concatenated raw content of the
/// given spans (one entry per line of the block). Backtick strings are
/// maximal runs of backticks whose first character is not backslash-escaped
/// (§2.4 example 14: `\`not code` is literal). Each string opens a code
/// span closed by the *next* string of equal length; strings of other
/// lengths are skipped (§6.1), and everything between opener and closer is
/// opaque (interior backticks never reopen).
///
/// The closer scan is deliberately *not* escape-aware: a backslash inside
/// the would-be content is literal ("backslash escapes do not work in code
/// spans"), so it cannot escape a following backtick — `\`foo\`bar` `
/// closes at the backtick after `foo\` (spec example).
fn discoverCodeSpans(doc: *document.Document, contents: []const source.Span, spans: *std.ArrayList(CodeSpan)) ParseError!void {
    const bytes = doc.src.bytes;
    const para_end = contents[contents.len - 1].end;
    const para_start = contents[0].start;

    var i = para_start;
    while (i < para_end) {
        // Normal-text scan: a run starts at an unescaped backtick that is
        // not itself part of a longer run ("neither preceded nor followed
        // by a backtick").
        const at_run_start = bytes[i] == '`' and
            !isEscaped(bytes, i) and
            (i == para_start or bytes[i - 1] != '`');
        if (at_run_start) {
            var e = i + 1;
            while (e < para_end and bytes[e] == '`') : (e += 1) {}
            const want = e - i;

            // Escape-free forward scan for a closing string of equal
            // length; longer/shorter strings are skipped.
            var j = e;
            var closer_start: ?u32 = null;
            while (j < para_end) : (j += 1) {
                if (bytes[j] != '`' or bytes[j - 1] == '`') continue;
                var k = j + 1;
                while (k < para_end and bytes[k] == '`') : (k += 1) {}
                if (k - j == want) {
                    closer_start = @intCast(j);
                    break;
                }
                j = k - 1; // different length: keep scanning past it
            }
            if (closer_start) |cs| {
                const close_end = cs + @as(u32, @intCast(want));
                try spans.append(doc.allocator(), .{
                    .span = .{ .start = @intCast(i), .end = close_end },
                    .content = .{ .start = @intCast(e), .end = cs },
                });
                i = close_end;
                continue;
            }
            i = e; // unclosed: literal backticks, resume after the run
            continue;
        }
        i += 1;
    }
}

/// True if the line terminator `[term.start, term.end)` lies inside a code
/// span's content (i.e. the line ends inside a span that closes on a later
/// line). Used to suppress break items: the line ending is then span
/// content, not a soft/hard break.
fn terminatorInsideCodeSpan(term: source.Span, spans: []const CodeSpan) bool {
    for (spans) |s| {
        if (s.content.start > term.start) return false; // sorted; later spans are past it
        if (term.start < s.content.end) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Inline pass: link discovery (scan -> match, second discovery pass).
// ---------------------------------------------------------------------------

/// The result of parsing an inline link's `(...)` part.
const LinkParts = struct {
    /// Position just after the link's closing `)`.
    paren_end: u32,
    /// The destination's content (excluding `<...>` for the angle form;
    /// empty for `()` / `(<> )`).
    dest: source.Span,
    /// The title's content (excluding its delimiters), when present.
    title: ?source.Span,
};

/// Parses an inline link's `(...)` part starting at `pos`, which must be
/// the `(` immediately following the link text's `]` (§6.6: "followed
/// immediately by a left parenthesis"). The four components — `(`, link
/// destination, link title, `)` — may be separated by spaces, tabs, and up
/// to one line ending; the destination may not contain a line ending, the
/// title may. Returns null when the text is not a valid inline link, in
/// which case the caller keeps the brackets as literal text.
fn tryParseLink(bytes: []const u8, pos: usize, para_end: usize) ?LinkParts {
    if (pos >= para_end or bytes[pos] != '(') return null;
    var p = pos + 1;
    p = skipLinkSep(bytes, p, para_end) orelse return null;

    var dest: ?source.Span = null;
    if (p < para_end) {
        if (bytes[p] == '<') {
            // Starts with `<`: only the angle form can follow (§6.6 "does
            // not start with `<`" for the bare form); a failed angle scan
            // fails the whole link.
            const end = scanAngleDest(bytes, p + 1, para_end) orelse return null;
            dest = .{ .start = @intCast(p + 1), .end = @intCast(end) };
            p = end + 1;
        } else if (scanBareDest(bytes, p, para_end)) |end| {
            dest = .{ .start = @intCast(p), .end = @intCast(end) };
            p = end;
        }
    }
    p = skipLinkSep(bytes, p, para_end) orelse return null;

    var title: ?source.Span = null;
    if (p < para_end and (bytes[p] == '"' or bytes[p] == '\'' or bytes[p] == '(')) {
        const t = scanTitle(bytes, p, para_end) orelse return null;
        title = t.content;
        p = t.end;
        p = skipLinkSep(bytes, p, para_end) orelse return null;
    }
    if (p < para_end and bytes[p] == ')') {
        return .{
            .paren_end = @intCast(p + 1),
            .dest = dest orelse .{ .start = @intCast(pos + 1), .end = @intCast(pos + 1) },
            .title = title,
        };
    }
    return null;
}

/// Skips the whitespace separating link components (§6.6): spaces, tabs,
/// and up to one line ending. Two line endings (or a blank line, which the
/// block pass would have split anyway) make the separator invalid.
/// `\r\n` counts as a single line ending.
fn skipLinkSep(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    var seen_eol = false;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ' ' or b == '\t') continue;
        if (b == '\n' or b == '\r') {
            if (seen_eol) return null;
            seen_eol = true;
            if (b == '\r' and p + 1 < para_end and bytes[p + 1] == '\n') p += 1;
            continue;
        }
        break;
    }
    return p;
}

/// Scans a bare link destination (§6.6): a nonempty sequence that does not
/// start with `<`, contains no spaces or ASCII control characters, and
/// includes parentheses only when backslash-escaped or balanced. Stops at
/// the first space/control character, at an unescaped `)` when the paren
/// depth is zero (that `)` is the link's own closing parenthesis), or at
/// the paragraph end. Returns null when the sequence is empty or the parens
/// are unbalanced at the stop point (e.g. `[link](foo(and(bar))` fails).
///
/// DoS guard: the spec lets implementations "impose limits on parentheses
/// nesting to avoid performance issues" (and at least three levels must
/// work), so a depth beyond `max_dest_depth` — or a scan longer than
/// `max_link_scan` — fails the destination instead of letting a hostile
/// `[a]([a]([a](...` line make every `]` rescan the whole paragraph.
fn scanBareDest(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    var depth: usize = 0;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == ' ' or b < 0x20 or b == 0x7f) break;
        if (b == '\\' and p + 1 < para_end and isAsciiPunctuation(bytes[p + 1])) {
            p += 1; // escaped character: literal, and not a paren/space
            continue;
        }
        if (b == '(') {
            depth += 1;
            if (depth > max_dest_depth) return null;
        } else if (b == ')') {
            if (depth == 0) break; // the link's closing parenthesis
            depth -= 1;
        }
    }
    if (p == start or depth != 0) return null;
    return p;
}

/// Scans an angle-bracketed link destination (`<...>`, §6.6): content with
/// no line endings and no unescaped `<` or `>`; the closing `>` must be
/// unescaped ("angle brackets that enclose links must be unescaped").
/// Returns the position of the closing `>`; null when the scan runs past
/// `max_link_scan` bytes (DoS guard, see `scanBareDest`).
fn scanAngleDest(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == '\n' or b == '\r') return null; // destinations cannot contain line endings
        if (b == '<' and !isEscaped(bytes, p)) return null;
        if (b == '>' and !isEscaped(bytes, p)) return p;
    }
    return null;
}

const TitleParts = struct {
    /// Content between the delimiters (raw bytes; line endings kept).
    content: source.Span,
    /// Position just after the closing delimiter.
    end: usize,
};

/// Scans a link title (§6.6): `"..."`, `'...'`, or `(...)`, where the
/// delimiting character appears inside only backslash-escaped (for the
/// paren form, the first unescaped `)` closes — a chosen reading, see
/// docs/FEATURE-MATRIX). Titles may span line endings (the block pass
/// bounds them: a blank line splits the paragraph). Returns null when no
/// closing delimiter is found, or when the scan runs past `max_link_scan`
/// bytes (DoS guard, see `scanBareDest`).
fn scanTitle(bytes: []const u8, start: usize, para_end: usize) ?TitleParts {
    const open = bytes[start];
    const close: u8 = if (open == '(') ')' else open;
    var p = start + 1;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == '\\' and p + 1 < para_end and isAsciiPunctuation(bytes[p + 1])) {
            p += 1; // escaped character: literal, never the closer
            continue;
        }
        if (b == close) {
            return .{
                .content = .{ .start = @intCast(start + 1), .end = @intCast(p) },
                .end = p + 1,
            };
        }
    }
    return null;
}

/// DoS guards for link-component scans (see `scanBareDest`): a paren depth
/// cap the spec explicitly permits, and a generous per-component scan cap.
const max_dest_depth: usize = 32;
const max_link_scan: usize = 2048;

/// Discovers inline links (§6.6) in the item list, restructuring it in
/// place. Walks the list with a bracket stack; on a `]` whose nearest `[`
/// opener is followed by a valid `(...)` link in the source, splices the
/// bracket range — plus the items covering the consumed `(...)` bytes —
/// into a single `link` item whose children are the link-text items, and
/// forgets every earlier `[` (links cannot contain links, so after a link
/// forms no earlier `[` can ever open). Brackets that never form a link
/// stay in the list and emit as literal text. Because a link inside a
/// bracket range would have killed that range's opener, link children
/// never contain links. Runs before emphasis matching: a link item is
/// opaque to the delimiter stack, and its children are matched separately.
fn discoverLinks(doc: *document.Document, items: *std.ArrayList(InlineItem), para_end: u32) ParseError!void {
    const bytes = doc.src.bytes;
    var out = std.ArrayList(InlineItem).empty;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(doc.allocator());

    const old = items.items;
    var i: usize = 0;
    while (i < old.len) : (i += 1) {
        const item = old[i];
        if (item == .bracket and item.bracket.ch == '[') {
            try out.append(doc.allocator(), item);
            try stack.append(doc.allocator(), out.items.len - 1);
            continue;
        }
        if (item == .bracket and item.bracket.ch == ']') {
            if (stack.items.len == 0) {
                try out.append(doc.allocator(), item);
                continue;
            }
            const o = stack.items[stack.items.len - 1];
            const close_end = item.bracket.span.end;
            if (tryParseLink(bytes, close_end, para_end)) |lp| {
                const open_start = out.items[o].bracket.span.start;

                // Children: the items between `[` and `]`. Never contains a
                // link (one would have killed this opener first).
                var children = std.ArrayList(InlineItem).empty;
                try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                // Consume the `(...)` items: everything after the `]` up to
                // (not including) the closing paren. The last consumed item
                // may extend past the paren (e.g. `[foo](/uri) and more`) —
                // truncate it so its tail stays literal.
                var j = i + 1;
                while (j < old.len and itemSpan(old[j]).start < lp.paren_end) : (j += 1) {}
                if (itemSpan(old[j - 1]).end > lp.paren_end) {
                    // The last consumed item extends past the closing paren
                    // (e.g. `[foo](/uri) and more`): truncate its tail so it
                    // stays literal text after the link.
                    setItemSpan(&old[j - 1], .{ .start = lp.paren_end, .end = itemSpan(old[j - 1]).end });
                    try out.append(doc.allocator(), old[j - 1]);
                }

                out.shrinkRetainingCapacity(o);
                try out.append(doc.allocator(), .{
                    .link = .{
                        .span = .{ .start = open_start, .end = lp.paren_end },
                        .children = children,
                        .dest = lp.dest,
                        .title = lp.title,
                    },
                });
                // Every earlier `[` is dead (links cannot contain links).
                stack.clearRetainingCapacity();
                i = j - 1; // the `(...)` items were consumed
                continue;
            }
            // Not a link: the opener can never match a later `]`.
            _ = stack.pop();
            try out.append(doc.allocator(), item);
            continue;
        }
        try out.append(doc.allocator(), item);
    }

    items.* = out; // moved; the old buffer stays in the arena
}

/// A delimiter run, classified once at scan time. `can_open`/`can_close`
/// follow rules 1–8; the same flags serve emphasis and strong emphasis
/// because for both `*` and `_` the single- and double-delimiter rules
/// classify runs identically (docs/INLINE-PARSING.md §6).
const DelimiterRun = struct {
    ch: u8,
    /// Bytes consumed by closer matches, from the front of the run.
    front_used: u32 = 0,
    /// Bytes consumed by opener matches, from the back of the run.
    back_used: u32 = 0,
    /// Full original run span in the source.
    span: source.Span,
    can_open: bool,
    can_close: bool,

    /// Delimiters not yet consumed by any match. The remaining bytes are the
    /// run's middle: [span.start + front_used, span.end - back_used).
    fn len(self: *const DelimiterRun) u32 {
        return @intCast(self.span.len() - self.front_used - self.back_used);
    }
};

/// Scans one line's raw content span into `items`. Flanking is computed
/// against the *raw* span (so trailing whitespace and line boundaries
/// classify runs correctly); emitted text is clamped to `emit`, which is
/// where the leading/trailing trimming decided by the block pass applies.
///
/// `spans` (sorted, disjoint) are the block's code spans; positions inside
/// a span are opaque — a code_span item is appended at the opening
/// backtick, and everything through the closing backtick is skipped.
fn scanLine(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    raw: source.Span,
    emit: source.Span,
    spans: []const CodeSpan,
) ParseError!void {
    const bytes = doc.src.bytes;
    var i = raw.start;
    var run_start = raw.start;
    var si: usize = 0;
    while (si < spans.len and spans[si].span.end <= raw.start) si += 1;
    while (i < raw.end) : (i += 1) {
        // Inside a span that opened on an earlier line: skip to its end;
        // the code_span item was appended when the span opened.
        if (si < spans.len and i > spans[si].span.start and i < spans[si].span.end) {
            i = spans[si].span.end - 1;
            run_start = spans[si].span.end;
            si += 1;
            continue;
        }
        // At a span opening: flush the preceding text, append the span
        // item, skip the whole construct.
        if (si < spans.len and i == spans[si].span.start) {
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            try items.append(doc.allocator(), .{
                .code_span = .{ .span = spans[si].span, .content = spans[si].content },
            });
            i = spans[si].span.end - 1;
            run_start = spans[si].span.end;
            si += 1;
            continue;
        }
        const b = bytes[i];
        if (b == '[' or b == ']') {
            if (isEscaped(bytes, i)) continue; // literal text, not a bracket
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            try items.append(doc.allocator(), .{
                .bracket = .{ .ch = b, .span = .{ .start = @intCast(i), .end = @intCast(i + 1) } },
            });
            run_start = i + 1;
        } else if (b == '*' or b == '_') {
            if (isEscaped(bytes, i)) continue; // literal text, not a delimiter
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);

            var e = i + 1;
            while (e < raw.end and bytes[e] == b and !isEscaped(bytes, e)) : (e += 1) {}
            const span = source.Span{ .start = @intCast(i), .end = @intCast(e) };
            try items.append(doc.allocator(), .{
                .delimiter = classifyRun(bytes, span, raw),
            });
            i = e - 1; // loop increments past the run
            run_start = e;
        }
    }
    try appendTextItem(doc, items, .{ .start = run_start, .end = raw.end }, emit);
}

fn appendTextItem(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    span: source.Span,
    emit: source.Span,
) ParseError!void {
    const start = @max(span.start, emit.start);
    const end = @min(span.end, emit.end);
    if (start >= end) return;
    try items.append(doc.allocator(), .{
        .text = .{ .start = @intCast(start), .end = @intCast(end) },
    });
}

/// Classifies a delimiter run per §6.2. The character *after* the run and
/// the character *before* it are decoded as code points; the beginning and
/// end of the line count as Unicode whitespace. A backslash directly after a
/// run is either a literal backslash or the escape marker of an escaped
/// ASCII-punctuation character — in both cases the following character is
/// punctuation, so the raw byte decode is exactly the rendered-stream
/// reading (see docs/INLINE-PARSING.md §16.1).
fn classifyRun(bytes: []const u8, span: source.Span, line: source.Span) DelimiterRun {
    const prev_char = if (span.start == line.start) null else unicode.decodePrev(bytes, span.start);
    const next_char = if (span.end == line.end) null else unicode.decode(bytes, span.end);

    const prev_ws = span.start == line.start or (prev_char != null and unicode.isWhitespace(prev_char.?));
    const prev_punct = prev_char != null and unicode.isPunctuation(prev_char.?);
    const next_ws = span.end == line.end or (next_char != null and unicode.isWhitespace(next_char.?));
    const next_punct = next_char != null and unicode.isPunctuation(next_char.?);

    // §6.2 flanking definitions.
    const left_flanking = !next_ws and (!next_punct or (next_punct and (prev_ws or prev_punct)));
    const right_flanking = !prev_ws and (!prev_punct or (prev_punct and (next_ws or next_punct)));

    // Rules 1–8. For `*`, opening/closing needs only the corresponding
    // flanking; for `_`, the stricter intraword rules with the
    // punctuation-adjacent (b) clauses.
    const ch = bytes[span.start];
    const can_open = left_flanking and
        (ch == '*' or !right_flanking or (right_flanking and prev_punct));
    const can_close = right_flanking and
        (ch == '*' or !left_flanking or (left_flanking and next_punct));

    return .{
        .ch = ch,
        .span = span,
        .can_open = can_open,
        .can_close = can_close,
    };
}

// ---------------------------------------------------------------------------
// Inline pass: delimiter stack matching.
// ---------------------------------------------------------------------------

/// One emphasis/strong match discovered by the match phase. Segment spans are
/// the *consumed* byte ranges of each run: the opener's back and the closer's
/// front (the ends adjacent to the matched content); leftover bytes are
/// literal text and lie outside them.
const Match = struct {
    kind: Kind,
    opener_item: usize,
    closer_item: usize,
    opener_seg: source.Span,
    closer_seg: source.Span,

    const Kind = enum { em, strong };
};

/// `openers_bottom` table: for each (delimiter character, closer length
/// mod 3), the number of entries at the bottom of the delimiter stack that
/// can never match a closer of that key. Raising it is what keeps matching
/// amortized linear (docs/INLINE-PARSING.md §8.5).
///
/// Deliberate chosen behavior: a closer's key is fixed at its *first*
/// processing (the original run length mod 3) and applies to leftover
/// re-loops too, and bottoms are shared across closer kinds. This reproduces
/// the reference behavior on inputs like `*****Hello*world****` (see
/// docs/FEATURE-MATRIX.md, "emphasis" row) and every verified spec example.
const Bottoms = struct {
    inner: [2][3]usize = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } },

    fn idx(ch: u8) usize {
        return if (ch == '*') 0 else 1;
    }

    fn get(self: *const Bottoms, ch: u8, m: usize) usize {
        return self.inner[idx(ch)][m];
    }

    fn set(self: *Bottoms, ch: u8, m: usize, v: usize) void {
        self.inner[idx(ch)][m] = v;
    }

    /// After popping the stack down to `keep` entries, dead entries above
    /// `keep` are gone; clamp every bottom so it never points past the
    /// stack.
    fn clampOnPop(self: *Bottoms, keep: usize) void {
        for (0..2) |i| {
            for (0..3) |j| {
                self.inner[i][j] = @min(self.inner[i][j], keep);
            }
        }
    }
};

/// Processes one delimiter item as a potential closer (and then, for any
/// leftover, as a potential opener). Runs left to right; `items` is not
/// resized during matching.
fn processDelimiter(
    doc: *document.Document,
    items: []InlineItem,
    stack: *std.ArrayList(usize),
    bottoms: *Bottoms,
    matches: *std.ArrayList(Match),
    c_idx: usize,
) ParseError!void {
    const c = &items[c_idx].delimiter;
    if (!c.can_close) {
        if (c.can_open) try stack.append(doc.allocator(), c_idx);
        return;
    }

    // The closer's key (length mod 3) is fixed at first processing and
    // applies to leftover re-loops (see Bottoms comment).
    const m: usize = c.len() % 3;

    while (c.len() > 0 and c.can_close) {
        const bottom = bottoms.get(c.ch, m);
        var j = stack.items.len;
        var matched = false;
        while (j > bottom) {
            j -= 1;
            const o_idx = stack.items[j];
            const o = &items[o_idx].delimiter;
            if (o.ch != c.ch) continue;
            if (!o.can_open or !mod3Allowed(o, c)) continue;

            // Consume from the opener's back and the closer's front (the
            // ends adjacent to the matched content); strong if both have at
            // least 2 delimiters left.
            const kind: Match.Kind = if (o.len() >= 2 and c.len() >= 2) .strong else .em;
            const take: u32 = if (kind == .strong) 2 else 1;
            const o_seg = source.Span{
                .start = o.span.end - o.back_used - take,
                .end = o.span.end - o.back_used,
            };
            const c_seg = source.Span{
                .start = c.span.start + c.front_used,
                .end = c.span.start + c.front_used + take,
            };
            o.back_used += take;
            c.front_used += take;
            try matches.append(doc.allocator(), .{
                .kind = kind,
                .opener_item = o_idx,
                .closer_item = c_idx,
                .opener_seg = o_seg,
                .closer_seg = c_seg,
            });

            // Everything at or above the opener is consumed: the opener
            // itself unless it still has delimiters left, and all trapped
            // openers above it (they lie inside the matched span).
            const keep = j + @intFromBool(o.len() > 0);
            bottoms.clampOnPop(keep);
            stack.shrinkRetainingCapacity(keep);
            matched = true;
            break;
        }
        if (!matched) {
            // Every opener examined is dead for this key.
            bottoms.set(c.ch, m, stack.items.len);
            break;
        }
    }

    if (c.len() > 0 and c.can_open) try stack.append(doc.allocator(), c_idx);
}

/// Rule 9/10 mod-3 test. Applies only when one of the two runs can both open
/// and close; the constraint is identical for emphasis and strong emphasis.
fn mod3Allowed(o: *const DelimiterRun, c: *const DelimiterRun) bool {
    if (!(o.can_open and o.can_close) and !(c.can_open and c.can_close)) return true;
    if ((o.len() + c.len()) % 3 != 0) return true;
    return o.len() % 3 == 0 and c.len() % 3 == 0;
}

/// Runs the match phase over the item list, then materializes document nodes
/// under `block`.
fn matchInlines(doc: *document.Document, block: *document.Node, items: []const InlineItem) ParseError!void {
    var stack = std.ArrayList(usize).empty;
    var bottoms = Bottoms{};
    var matches = std.ArrayList(Match).empty;

    // The match phase mutates only `front_used`/`back_used` inside delimiter
    // items; the item list itself is stable, so it is safe to alias it into
    // a mutable slice.
    const mutable = @constCast(items);
    for (mutable, 0..) |item, i| {
        if (item != .delimiter) continue;
        try processDelimiter(doc, mutable, &stack, &bottoms, &matches, i);
    }

    try emitInlines(doc, block, mutable, matches.items);
}

// ---------------------------------------------------------------------------
// Inline pass: emission.
// ---------------------------------------------------------------------------

/// Materializes document nodes from the matched item list. Frames (open
/// emphasis/strong nodes) are tracked on an explicit stack; nesting depth
/// never consumes the call stack.
fn emitInlines(
    doc: *document.Document,
    block: *document.Node,
    items: []const InlineItem,
    matches: []const Match,
) ParseError!void {
    const n = items.len;
    const alloc = doc.allocator();

    // Bucket matches by opener item and by closer item (two counting passes,
    // so emission is linear in items + matches). `off[i]` starts as the
    // count of matches at item i, then becomes the start offset of item i's
    // bucket; `off[n]` is the total. In-place prefix sums: the count at
    // position i is consumed into the accumulator *after* the prefix is
    // written there, so the bucket for item i spans [off[i], off[i + 1]).
    const opener_off = try alloc.alloc(usize, n + 1);
    const closer_off = try alloc.alloc(usize, n + 1);
    @memset(opener_off, 0);
    @memset(closer_off, 0);
    for (matches) |m| {
        opener_off[m.opener_item] += 1;
        closer_off[m.closer_item] += 1;
    }
    var acc: usize = 0;
    for (0..n) |i| {
        const count = opener_off[i];
        opener_off[i] = acc;
        acc += count;
    }
    opener_off[n] = acc;
    acc = 0;
    for (0..n) |i| {
        const count = closer_off[i];
        closer_off[i] = acc;
        acc += count;
    }
    closer_off[n] = acc;
    const opener_idx = try alloc.alloc(usize, matches.len);
    const closer_idx = try alloc.alloc(usize, matches.len);
    {
        var cursor = try alloc.dupe(usize, opener_off[0..n]);
        for (matches, 0..) |m, k| {
            const i = m.opener_item;
            opener_idx[cursor[i]] = k;
            cursor[i] += 1;
        }
    }
    {
        var cursor = try alloc.dupe(usize, closer_off[0..n]);
        for (matches, 0..) |m, k| {
            const i = m.closer_item;
            closer_idx[cursor[i]] = k;
            cursor[i] += 1;
        }
    }

    var frames = std.ArrayList(*document.Node).empty;
    var current = block;

    for (items, 0..) |item, i| {
        switch (item) {
            .text => |span| try emitTextRuns(doc, current, span),
            .brk => |brk| {
                const node = try doc.createNode(
                    if (brk.kind == .hard) .hard_break else .soft_break,
                    brk.span,
                    .none,
                );
                try doc.appendChild(current, node);
            },
            .code_span => |cs| {
                const node = try doc.createNode(.code_span, cs.span, .{
                    .code_span = try normalizeCodeSpan(doc, cs.content),
                });
                try doc.appendChild(current, node);
            },
            .bracket => |br| try emitText(doc, current, br.span),
            .link => |lk| {
                // The link's text is a fresh inline scope: children are
                // matched with the `[` opener as stack_bottom (the spec's
                // "process emphasis" call), so they never see delimiters
                // outside the brackets — and they contain no links (see
                // discoverLinks).
                const node = try doc.createNode(.link, lk.span, .{
                    .link = .{
                        .href = try resolveEscapes(doc, lk.dest),
                        .title = if (lk.title) |ts| try resolveEscapes(doc, ts) else null,
                    },
                });
                try doc.appendChild(current, node);
                try matchInlines(doc, node, lk.children.items);
            },
            .delimiter => |run| {
                const o_start = opener_off[i];
                const o_end = opener_off[i + 1];
                const c_start = closer_off[i];
                const c_end = closer_off[i + 1];

                // Leftover delimiters are the run's middle: consumed bytes
                // were taken from the front (as closer) and the back (as
                // opener). This is the source range [start + front_used,
                // end - back_used).
                const leftover = run.len();

                // Close frames for closer matches, innermost first. Matches
                // closing here are exactly the frames on top of the stack
                // (an opener trapped above a matched opener is consumed by
                // that match, never matched later), so the stack discipline
                // holds.
                if (c_end > c_start) {
                    const bucket = closer_idx[c_start..c_end];
                    std.mem.sort(usize, bucket, matches, closerLess);
                    for (bucket) |_| {
                        _ = frames.pop();
                        current = if (frames.items.len > 0)
                            frames.items[frames.items.len - 1]
                        else
                            block;
                    }
                }

                // Leftover delimiters are literal text. Emitted after the
                // frames they close (a closer's leftover sits inside the
                // byte range but outside the matched span, e.g. `*foo***`)
                // and before the frames they open (an opener's leftover
                // precedes its consumed bytes, e.g. `***foo**`).
                if (leftover > 0) {
                    try emitText(doc, current, .{
                        .start = run.span.start + run.front_used,
                        .end = run.span.end - run.back_used,
                    });
                }

                // Open frames for opener matches, outermost first (smallest
                // consumed offset).
                if (o_end > o_start) {
                    const obucket = opener_idx[o_start..o_end];
                    std.mem.sort(usize, obucket, matches, openerLess);
                    for (obucket) |k| {
                        const m = matches[k];
                        const node = try doc.createNode(
                            if (m.kind == .strong) .strong else .emphasis,
                            .{ .start = m.opener_seg.start, .end = m.closer_seg.end },
                            .none,
                        );
                        try doc.appendChild(current, node);
                        try frames.append(doc.allocator(), node);
                        current = node;
                    }
                }
            },
        }
    }
}

/// Closer matches at one item close innermost-first: the frame opened most
/// recently (largest opener position) is on top.
fn closerLess(ctx: []const Match, a: usize, b: usize) bool {
    const ma = ctx[a];
    const mb = ctx[b];
    if (ma.opener_item != mb.opener_item) return ma.opener_item > mb.opener_item;
    return ma.opener_seg.start > mb.opener_seg.start;
}

/// Opener matches at one item open outermost-first: smallest consumed offset
/// first.
fn openerLess(ctx: []const Match, a: usize, b: usize) bool {
    const ma = ctx[a];
    const mb = ctx[b];
    return ma.opener_seg.start < mb.opener_seg.start;
}

/// Emits text nodes for the content range, resolving backslash escapes
/// (§2.4): a backslash before an ASCII punctuation character produces that
/// character literally (the backslash is consumed, so it is not covered by
/// any node's span); a backslash before anything else is a literal
/// backslash. Each escape splits the text into adjacent text nodes.
fn emitTextRuns(doc: *document.Document, parent: *document.Node, span: source.Span) ParseError!void {
    if (span.isEmpty()) return;
    const bytes = doc.src.bytes;

    var i = span.start;
    var run_start = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < span.end and isAsciiPunctuation(bytes[i + 1])) {
            try emitText(doc, parent, .{ .start = run_start, .end = i });
            try emitText(doc, parent, .{ .start = i + 1, .end = i + 2 });
            i += 1;
            run_start = i + 1;
        }
    }
    try emitText(doc, parent, .{ .start = run_start, .end = span.end });
}

/// §6.1 normalization of a code span's raw content: line endings become
/// spaces; if the result both begins and ends with a space (U+0020 — "Only
/// [spaces], and not unicode whitespace in general, are stripped") and does
/// not consist entirely of spaces, one space is removed from the front and
/// back. The result is copied into the document arena: it is the one text
/// payload not borrowed from the source (docs/DOCUMENT-MODEL.md).
fn normalizeCodeSpan(doc: *document.Document, content: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;
    if (content.isEmpty()) return "";

    // Pass 1: normalized length (a line ending \n, \r\n, or \r is one
    // space).
    var n: usize = 0;
    var i = content.start;
    while (i < content.end) : (i += 1) {
        if (bytes[i] == '\r') {
            if (i + 1 < content.end and bytes[i + 1] == '\n') i += 1;
        }
        n += 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = content.start;
    while (i < content.end) : (i += 1) {
        const b = bytes[i];
        if (b == '\n' or b == '\r') {
            if (b == '\r' and i + 1 < content.end and bytes[i + 1] == '\n') i += 1;
            buf[k] = ' ';
        } else {
            buf[k] = b;
        }
        k += 1;
    }

    if (n >= 2 and buf[0] == ' ' and buf[n - 1] == ' ' and !allSpaces(buf)) {
        return buf[1 .. n - 1];
    }
    return buf;
}

fn allSpaces(s: []const u8) bool {
    for (s) |b| {
        if (b != ' ') return false;
    }
    return true;
}

/// Resolves §2.4 backslash escapes into an arena-owned copy: `\X` where X
/// is ASCII punctuation becomes the literal character X (the backslash is
/// dropped); a backslash before anything else is a literal backslash. Used
/// for link destinations and titles (§6.6: "with backslash-escapes in
/// effect as described above"), which cannot borrow the source because the
/// escapes are consumed. Line endings are kept verbatim (titles may span
/// lines).
fn resolveEscapes(doc: *document.Document, span: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;
    var n: usize = 0;
    var i = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < span.end and isAsciiPunctuation(bytes[i + 1])) {
            i += 1;
        }
        n += 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < span.end and isAsciiPunctuation(bytes[i + 1])) {
            buf[k] = bytes[i + 1];
            i += 1;
        } else {
            buf[k] = bytes[i];
        }
        k += 1;
    }
    return buf;
}

fn emitText(doc: *document.Document, parent: *document.Node, span: source.Span) ParseError!void {
    if (span.isEmpty()) return;
    // Contiguous text in the same parent merges into one node: scanning
    // artifacts (item boundaries, leftover delimiters, escape splits) must
    // not fragment the normalized model. The merged span covers adjacent
    // source bytes, so the borrowed text payload is exact.
    if (parent.children.items.len > 0) {
        const last = parent.children.items[parent.children.items.len - 1];
        if (last.tag == .text and last.span.end == span.start) {
            last.span.end = span.end;
            last.data.text = doc.text(last.span);
            return;
        }
    }
    const node = try doc.createNode(.text, span, .{ .text = doc.text(span) });
    try doc.appendChild(parent, node);
}

// ---------------------------------------------------------------------------
// Character classes and helpers.
// ---------------------------------------------------------------------------

/// §2.1: ASCII punctuation is U+0021–2F, U+003A–0040, U+005B–0060,
/// U+007B–007E — the only characters backslash escapes may escape.
fn isAsciiPunctuation(b: u8) bool {
    return switch (b) {
        '!'...'/' => true,
        ':'...'@' => true,
        '['...'`' => true,
        '{'...'~' => true,
        else => false,
    };
}

/// True if the byte at index `i` is preceded by an odd number of backslashes
/// (i.e., that backslash escapes it). Safe at `i == 0`. A line terminator is
/// never a backslash, so escape parity never leaks across lines.
fn isEscaped(bytes: []const u8, i: usize) bool {
    var n: usize = 0;
    var j = i;
    while (j > 0 and bytes[j - 1] == '\\') : (j -= 1) {
        n += 1;
    }
    return n % 2 == 1;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "markdown: paragraphs, soft breaks, ATX headings end to end" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "Foo bar\n# baz\nBar foo", .markdown, .{});
    defer result.deinit();

    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    try testing.expectEqual(document.Tag.heading, result.document.root.children.items[1].tag);
    try testing.expectEqual(@as(u8, 1), result.document.root.children.items[1].data.heading);
    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[2].tag);
}

test "markdown: heading recognition edge cases" {
    const oliver = @import("oliver.zig");

    // Tab after the opening # is accepted whitespace (spec §2.2 example 10).
    {
        var result = try oliver.parse(testing.allocator, "#\tfoo", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqualStrings("foo", h.children.items[0].data.text);
    }
    // A leading tab disqualifies the line in the slice (deferred).
    {
        var result = try oliver.parse(testing.allocator, "\t# foo", .markdown, .{});
        defer result.deinit();
        try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
}

test "markdown: source spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# hello", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(source.Span{ .start = 0, .end = 7 }, h.span);
    const t = h.children.items[0];
    try testing.expectEqual(source.Span{ .start = 2, .end = 7 }, t.span);
}

test "markdown: escapes produce literal characters with precise spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "a\\*b", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // The escape marker is covered by no node; the escaped * (span {2,3}) is
    // contiguous with "b" (span {3,4}) and merges into one text node.
    try testing.expectEqual(@as(usize, 2), p.children.items.len); // "a", "*b"
    try testing.expectEqualStrings("a", p.children.items[0].data.text);
    try testing.expectEqual(source.Span{ .start = 0, .end = 1 }, p.children.items[0].span);
    try testing.expectEqual(source.Span{ .start = 2, .end = 4 }, p.children.items[1].span);
    try testing.expectEqualStrings("*b", p.children.items[1].data.text);
}

test "markdown: hard breaks" {
    const oliver = @import("oliver.zig");

    // Two trailing spaces.
    {
        var result = try oliver.parse(testing.allocator, "foo  \nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        // The trailing spaces are not covered by any text node.
        try testing.expectEqual(source.Span{ .start = 0, .end = 3 }, p.children.items[0].span);
    }
    // One trailing space is a soft break.
    {
        var result = try oliver.parse(testing.allocator, "foo \nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    }
    // An unescaped trailing backslash is a hard break.
    {
        var result = try oliver.parse(testing.allocator, "foo\\\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    }
    // An escaped backslash (`\\`) is literal text, not a hard break. The
    // escape splits into adjacent text nodes: "foo", then the literal `\`.
    {
        var result = try oliver.parse(testing.allocator, "foo\\\\\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        try testing.expectEqualStrings("\\", p.children.items[1].data.text);
        try testing.expectEqual(document.Tag.soft_break, p.children.items[2].tag);
    }
    // Trailing spaces on the last line are consumed without a break node.
    {
        var result = try oliver.parse(testing.allocator, "foo  ", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    }
}

test "markdown: trailing tabs do not trigger hard breaks" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "foo\t\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    }
    {
        // Two spaces before the tab still count.
        var result = try oliver.parse(testing.allocator, "foo  \t\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    }
}

test "markdown: ATX closing sequences ignore escaped hashes (spec example 76)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "### foo \\###\n## foo #\\##\n# foo \\#", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);
    try testing.expectEqualStrings("foo ###", try inlineText(&result.document, root.children.items[0]));
    try testing.expectEqualStrings("foo ###", try inlineText(&result.document, root.children.items[1]));
    try testing.expectEqualStrings("foo #", try inlineText(&result.document, root.children.items[2]));
}

test "markdown: escapes inside headings" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# \\# not closing", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqualStrings("# not closing", try inlineText(&result.document, h));
}

// --- emphasis and strong emphasis (docs/INLINE-PARSING.md §6) ---

test "markdown: emphasis structure, spans, and literal fallback" {
    const oliver = @import("oliver.zig");

    // *foo* — emphasis node spans the whole construct; the consumed
    // delimiters are covered by no node.
    {
        var result = try oliver.parse(testing.allocator, "*foo*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(source.Span{ .start = 0, .end = 5 }, em.span);
        const t = em.children.items[0];
        try testing.expectEqual(document.Tag.text, t.tag);
        try testing.expectEqualStrings("foo", t.data.text);
        try testing.expectEqual(source.Span{ .start = 1, .end = 4 }, t.span);
    }
    // A bare run with no opener is literal text.
    {
        var result = try oliver.parse(testing.allocator, "* a *", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("* a *", p.children.items[0].data.text);
    }
}

test "markdown: intraword asterisks work, underscores do not" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "foo*bar*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "5*6*78", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, p.children.items[2].tag);
        try testing.expectEqualStrings("5", p.children.items[0].data.text);
        try testing.expectEqualStrings("6", p.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("78", p.children.items[2].data.text);
    }
    {
        var result = try oliver.parse(testing.allocator, "foo_bar_baz", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("foo_bar_baz", p.children.items[0].data.text);
    }
    {
        var result = try oliver.parse(testing.allocator, "5__6__78", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("5__6__78", p.children.items[0].data.text);
    }
}

test "markdown: strong emphasis and nesting" {
    const oliver = @import("oliver.zig");

    {
        var result = try oliver.parse(testing.allocator, "**foo**", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.strong, p.children.items[0].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].children.items[0].data.text);
    }
    // *foo **bar** baz* nests.
    {
        var result = try oliver.parse(testing.allocator, "*foo **bar** baz*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, p.children.items[0].tag);
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.text, em.children.items[0].tag);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, em.children.items[2].tag);
        try testing.expectEqualStrings("foo ", em.children.items[0].data.text);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings(" baz", em.children.items[2].data.text);
    }
}

test "markdown: mod-3 rule (spec examples)" {
    const oliver = @import("oliver.zig");

    // *foo**bar**baz*: the middle ** cannot close against the first *
    // (1+2 = 3), so it opens instead; the second ** closes it as strong.
    {
        var result = try oliver.parse(testing.allocator, "*foo**bar**baz*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(@as(usize, 3), em.children.items.len);
        try testing.expectEqualStrings("foo", em.children.items[0].data.text);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("baz", em.children.items[2].data.text);
    }
    // *foo**bar***: the split closer (`***` closes strong with 2, then the
    // leftover `*` closes the outer emphasis).
    {
        var result = try oliver.parse(testing.allocator, "*foo**bar***", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(@as(usize, 2), em.children.items.len);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
    }
    // ***foo** bar*: strong consumes ** of the *** opener, the leftover *
    // opens emphasis closed by the final *.
    {
        var result = try oliver.parse(testing.allocator, "***foo** bar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.strong, em.children.items[0].tag);
        try testing.expectEqualStrings(" bar", em.children.items[1].data.text);
    }
    // **foo*bar*baz** → strong with a literal inner *.
    {
        var result = try oliver.parse(testing.allocator, "**foo*bar*baz**", .markdown, .{});
        defer result.deinit();
        const strong = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.strong, strong.tag);
        try testing.expectEqual(document.Tag.emphasis, strong.children.items[1].tag);
    }
    // **foo*bar** → the trapped * is literal inside strong; the three
    // contiguous text runs merge into one node.
    {
        var result = try oliver.parse(testing.allocator, "**foo*bar**", .markdown, .{});
        defer result.deinit();
        const strong = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.strong, strong.tag);
        try testing.expectEqual(@as(usize, 1), strong.children.items.len);
        try testing.expectEqualStrings("foo*bar", strong.children.items[0].data.text);
        try testing.expectEqual(source.Span{ .start = 2, .end = 9 }, strong.children.items[0].span);
    }
    // The reference behavior for the untested corner case (see matrix).
    {
        var result = try oliver.parse(testing.allocator, "*****Hello*world****", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, p.children.items[2].tag);
        try testing.expectEqualStrings("*****Hello", p.children.items[0].data.text);
        try testing.expectEqualStrings("world", p.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("***", p.children.items[2].data.text);
    }
}

test "markdown: escaped delimiters are literal, not delimiters" {
    const oliver = @import("oliver.zig");

    // \*foo* — the first * is escaped, so nothing opens; all literal.
    {
        var result = try oliver.parse(testing.allocator, "\\*foo*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("*foo*", p.children.items[0].data.text);
    }
    // \\*emphasis* — the escaped backslash is literal, then real emphasis.
    {
        var result = try oliver.parse(testing.allocator, "\\\\*emphasis*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("\\", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
    }
}

test "markdown: emphasis spans soft and hard breaks" {
    const oliver = @import("oliver.zig");

    {
        var result = try oliver.parse(testing.allocator, "*foo\nbar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.text, em.children.items[0].tag);
        try testing.expectEqual(document.Tag.soft_break, em.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, em.children.items[2].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "*foo  \nbar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.hard_break, em.children.items[1].tag);
    }
}

test "markdown: emphasis in headings" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# foo *bar* \\*baz\\*", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqualStrings("foo ", h.children.items[0].data.text);
    try testing.expectEqual(document.Tag.emphasis, h.children.items[1].tag);
    try testing.expectEqualStrings("bar", h.children.items[1].children.items[0].data.text);
    // The escaped stars are literal; escape splits merge where contiguous:
    // " " (gap from the consumed backslash), then "*baz" (star + baz), then
    // a final escaped star.
    try testing.expectEqualStrings(" ", h.children.items[2].data.text);
    try testing.expectEqualStrings("*baz", h.children.items[3].data.text);
    try testing.expectEqualStrings("*", h.children.items[4].data.text);
}

test "markdown: code spans basic structure and content" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "`foo`", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
    try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
}

test "markdown: code span run-length matching" {
    const oliver = @import("oliver.zig");
    {
        // Open with 2, close with 1: no match; the run of 1 closes a span
        // opened at the first backtick of the pair (spec 335/336 shape).
        var result = try oliver.parse(testing.allocator, "`foo``bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo``bar", p.children.items[0].data.code_span);
    }
    {
        // Open with 2, close with 2.
        var result = try oliver.parse(testing.allocator, "``foo``", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
    }
    {
        // A length-1 run inside a length-2 span is opaque (spec 336).
        var result = try oliver.parse(testing.allocator, "``foo`bar``", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo`bar", p.children.items[0].data.code_span);
    }
    {
        // Content containing a longer run than the delimiters (spec 337).
        var result = try oliver.parse(testing.allocator, "` foo `` bar `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo `` bar", p.children.items[0].data.code_span);
    }
    {
        // Unmatched opening backticks stay literal (spec 347 shape).
        var result = try oliver.parse(testing.allocator, "`foo", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqualStrings("`foo", p.children.items[0].data.text);
    }
}

test "markdown: code span trim rule uses ASCII spaces only" {
    const oliver = @import("oliver.zig");
    {
        // One space each side is stripped (spec 335).
        var result = try oliver.parse(testing.allocator, "` foo `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
    }
    {
        // Entirely-space content is kept (spec 339).
        var result = try oliver.parse(testing.allocator, "`  `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("  ", p.children.items[0].data.code_span);
    }
    {
        // Tabs are not spaces: no trimming (spec 344's note).
        var result = try oliver.parse(testing.allocator, "`\tfoo\t`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("\tfoo\t", p.children.items[0].data.code_span);
    }
    {
        // Only one space is stripped per side.
        var result = try oliver.parse(testing.allocator, "`  foo  `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings(" foo ", p.children.items[0].data.code_span);
    }
}

test "markdown: code span newlines become spaces and escapes are inert" {
    const oliver = @import("oliver.zig");
    {
        // Line endings inside a code span become spaces.
        var result = try oliver.parse(testing.allocator, "`foo\nbar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo bar", p.children.items[0].data.code_span);
    }
    {
        // Backslash does not escape a backtick; the span closes early
        // (spec 340).
        var result = try oliver.parse(testing.allocator, "`foo\\`bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo\\", p.children.items[0].data.code_span);
        // The remainder is one contiguous text node: "bar`".
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("bar`", p.children.items[1].data.text);
    }
    {
        // Backslashes inside are kept literally.
        var result = try oliver.parse(testing.allocator, "`a\\b`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("a\\b", p.children.items[0].data.code_span);
    }
}

test "markdown: code span delimits emphasis (opacity precedence)" {
    const oliver = @import("oliver.zig");
    {
        // The star inside the span is not a delimiter (spec 341).
        var result = try oliver.parse(testing.allocator, "*foo`*`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("*foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
        try testing.expectEqualStrings("*", p.children.items[1].data.code_span);
    }
    {
        // Emphasis wraps a code span (spec 346).
        var result = try oliver.parse(testing.allocator, "*`foo`*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, p.children.items[0].tag);
        const em = p.children.items[0];
        try testing.expectEqual(@as(usize, 1), em.children.items.len);
        try testing.expectEqual(document.Tag.code_span, em.children.items[0].tag);
    }
    {
        // A single closing backtick leaves trailing text literal (spec 342).
        var result = try oliver.parse(testing.allocator, "`foo`bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("bar`", p.children.items[1].data.text);
    }
}

test "markdown: code span node span covers the construct, content excludes backticks" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "a `foo` b", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    const cs = p.children.items[1];
    try testing.expectEqual(document.Tag.code_span, cs.tag);
    // The node span is the whole construct: opening backtick .. closing
    // backtick (2..7). The normalized payload excludes them.
    const s = cs.span;
    try testing.expectEqual(@as(u32, 2), s.start);
    try testing.expectEqual(@as(u32, 7), s.end);
    try testing.expectEqualStrings("foo", cs.data.code_span);
}

// --- inline links (docs/INLINE-PARSING.md §6.6) ---

test "markdown: link structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo](/uri \"title\")", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    // The node span covers the whole construct: `[` .. `)`.
    try testing.expectEqual(source.Span{ .start = 0, .end = 19 }, lnk.span);
    try testing.expectEqualStrings("/uri", lnk.data.link.href);
    try testing.expectEqualStrings("title", lnk.data.link.title.?);
    // Children are the link text inlines.
    try testing.expectEqual(@as(usize, 1), lnk.children.items.len);
    try testing.expectEqual(document.Tag.text, lnk.children.items[0].tag);
    try testing.expectEqual(source.Span{ .start = 1, .end = 4 }, lnk.children.items[0].span);
    try testing.expectEqualStrings("foo", lnk.children.items[0].data.text);
}

test "markdown: link text holds inlines, not just text" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[a *b* `c`](/u)", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqual(@as(usize, 4), lnk.children.items.len);
    try testing.expectEqual(document.Tag.text, lnk.children.items[0].tag);
    try testing.expectEqual(document.Tag.emphasis, lnk.children.items[1].tag);
    try testing.expectEqual(document.Tag.text, lnk.children.items[2].tag);
    try testing.expectEqual(document.Tag.code_span, lnk.children.items[3].tag);
    try testing.expectEqualStrings("b", lnk.children.items[1].children.items[0].data.text);
}

test "markdown: link destination and title resolve backslash escapes" {
    const oliver = @import("oliver.zig");
    // Markdown source `[x](\(foo\) "ti\*tle")`: escaped parens in the
    // destination, an escaped `*` in the title. The escapes are consumed,
    // so the payloads are arena copies, not source slices (like code_span).
    var result = try oliver.parse(testing.allocator, "[x](\\(foo\\) \"ti\\*tle\")", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqualStrings("(foo)", lnk.data.link.href);
    try testing.expectEqualStrings("ti*tle", lnk.data.link.title.?);
    // A backslash before a non-punctuation character is literal.
    var result2 = try oliver.parse(testing.allocator, "[x](foo\\bar)", .markdown, .{});
    defer result2.deinit();
    const lnk2 = result2.document.root.children.items[0].children.items[0];
    try testing.expectEqualStrings("foo\\bar", lnk2.data.link.href);
}

test "markdown: link brackets bind more tightly than emphasis" {
    const oliver = @import("oliver.zig");
    // `*[foo*](/uri)`: the `*` before `[` cannot open — the link consumes
    // the inner `*` — and the trailing `*` is inside the link text.
    var result = try oliver.parse(testing.allocator, "*[foo*](/uri)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try testing.expectEqualStrings("*", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("foo*", (try inlineText(&result.document, p.children.items[1])));
}

test "markdown: links cannot contain links, innermost wins" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo [bar](/uri)](/uri)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // `[foo ` + link + `](/uri)` — the outer brackets stay literal.
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqualStrings("[foo ", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", (try inlineText(&result.document, p.children.items[1])));
    try testing.expectEqualStrings("](/uri)", p.children.items[2].data.text);
}

test "markdown: code spans bind more tightly than link brackets" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo`](/uri)`", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // The code span runs from the first backtick to the last one, so the
    // `]` never closes the `[` — the whole thing is text + one code span.
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqualStrings("[foo", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
    try testing.expectEqualStrings("](/uri)", p.children.items[1].data.code_span);
}

test "markdown: emphasis can wrap a link" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "*[foo](/uri)*", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const em = p.children.items[0];
    try testing.expectEqual(document.Tag.emphasis, em.tag);
    try testing.expectEqual(@as(usize, 1), em.children.items.len);
    try testing.expectEqual(document.Tag.link, em.children.items[0].tag);
}

test "markdown: link failures stay literal" {
    const oliver = @import("oliver.zig");
    // Space before `(`: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo] (url)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo] (url)", p.children.items[0].data.text);
    }
    // Unbalanced destination parens: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo](bar(baz)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo](bar(baz)", p.children.items[0].data.text);
    }
    // Unclosed title: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo](/url \"x", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo](/url \"x", p.children.items[0].data.text);
    }
    // Balanced brackets inside link text are fine.
    {
        var result = try oliver.parse(testing.allocator, "[a [b] c](/u)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
        try testing.expectEqualStrings("a [b] c", (try inlineText(&result.document, p.children.items[0])));
    }
}

test "markdown: link text can span lines with a soft break inside" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[a\nb](/u)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    // Children: `a`, soft break, `b`.
    try testing.expectEqual(@as(usize, 3), lnk.children.items.len);
    try testing.expectEqual(document.Tag.soft_break, lnk.children.items[1].tag);
    // The link consumes the `(/u)` bytes; nothing literal leaks after it.
    try testing.expectEqual(source.Span{ .start = 0, .end = 9 }, lnk.span);
}

test "markdown: link title spans lines, destination does not" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[x](/u 't\na')", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("t\na", lnk.data.link.title.?);

    // A destination cannot contain a line ending (unlike a separator:
    // `[x](/u\n'a')` above is a valid link with a one-line-ending
    // separator). Here the line ending is inside the would-be destination,
    // so no link forms and the two lines stay a paragraph with a soft
    // break — rendering `[x](/u\nv)`, the spec's shape.
    var result2 = try oliver.parse(testing.allocator, "[x](/u\nv)", .markdown, .{});
    defer result2.deinit();
    const p2 = result2.document.root.children.items[0];
    // text `[x](/u`, soft break, text `v)` — renders `[x](/u\nv)`.
    try testing.expectEqual(@as(usize, 3), p2.children.items.len);
    try testing.expectEqualStrings("[x](/u", p2.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, p2.children.items[1].tag);
    try testing.expectEqualStrings("v)", p2.children.items[2].data.text);
}

test "markdown: link in heading, empty href, quote destination" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "# [foo](/uri)", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqual(document.Tag.link, h.children.items[0].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "[x]()", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqualStrings("", lnk.data.link.href);
        try testing.expectEqual(@as(?[]const u8, null), lnk.data.link.title);
    }
    // `[link]("title")`: the quoted string parses as a destination.
    {
        var result = try oliver.parse(testing.allocator, "[link](\"title\")", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqualStrings("\"title\"", lnk.data.link.href);
        try testing.expectEqual(@as(?[]const u8, null), lnk.data.link.title);
    }
}

/// Concatenates a node's inline text payloads (escapes split text into
/// adjacent nodes, so structural tests join them).
fn inlineText(doc: *document.Document, node: *document.Node) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(doc.allocator());
    for (node.children.items) |child| {
        try buf.appendSlice(doc.allocator(), child.data.text);
    }
    return buf.toOwnedSlice(doc.allocator());
}
