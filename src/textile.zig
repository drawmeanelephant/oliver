//! Textile frontend.
//!
//! Blocks: paragraphs, `h1.`–`h6.` headings, single-period `bq.` block
//! quotes, `*`/`#` lists with marker-depth nesting, and `|a|b|` tables
//! (single-line rows with cell modifiers, an optional `table<mods>.`
//! signature, colspan/rowspan, and Textile 2's header-alignment
//! propagation). Inlines: plain text,
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
//! - `[alias]url` lines anywhere in the document define link aliases; a
//!   `"text":alias` link resolves to the defined URL even when the
//!   definition comes later (both references document the lookup table).
//!   Definition lines never render (docs/TEXTILE-PARITY.md §7).
//! - Paragraph content is preserved verbatim (only the marker's separator
//!   whitespace is consumed).
//! - `h0.` and `h7.`+ are not headings; they remain paragraph text.
//! - A list item is a single line: `*` (bullet) or `#` (ordered) markers,
//!   one per nesting level, followed by a space or tab. Consecutive marker
//!   lines compose a tree of tight lists; a blank line, a block signature,
//!   or a non-marker text line closes all open lists (docs/TEXTILE-PARITY.md
//!   §6).
//! - A table is its own block: consecutive row lines (`|a|b|`, or rows with
//!   leading modifiers) compose one table until a blank line or any other
//!   block-level line. An optional `table<mods>.` signature opens one, with
//!   the first row on the same line (Textile 2) or on following lines
//!   (Hobix). A row must start with `|` (after modifiers) and end with `|`;
//!   every `|` splits (Textile has no pipe escape). Cell modifiers are
//!   terminated by a period followed by a space (the documented contract);
//!   row modifiers end at the first `|` (Textile 2) or after `. ` (Hobix).
//!   A header cell's alignment becomes the default for the cells below it
//!   in the same column (Textile 2); cells render as flat `<tr>` rows with
//!   no thead/tbody (docs/TEXTILE-PARITY.md §7).
//! - Block signatures carry the full attribute set: `p{style}.`,
//!   `p(class#id).`, `p[lang].`, `p().` indentation, and `p<.`/`p>.`/`p=.`/
//!   `p<>.` alignment — the modifiers sit between the marker and its
//!   period, for `p`, `bq`, and `hN` alike (Hobix §4;
//!   docs/TEXTILE-PARITY.md §8).
//! - `bc.` block code and `pre.` preformatted text open a leaf that owns
//!   every following non-blank line verbatim until a blank line (Textile 2:
//!   "a block ends with the first blank line"). `bc` escapes `<`/`>` and
//!   renders `<pre><code>`; `pre` is verbatim `<pre>`.
//! - Extended signatures (`bq..`, `bc..`, `pre..`, optional modifiers
//!   before the double period) stay active across blank lines until the
//!   next block signature (Textile 2 "Extended Blocks"): `bq..` becomes
//!   one blockquote of blank-line-separated paragraphs, and `bc..`/`pre..`
//!   keep blank lines as code content.
//! - Footnotes: `[N]` inline becomes `<sup class="footnote"><a
//!   href="#fnN">N</a></sup>`, and an `fnN.` paragraph renders
//!   `<p class="footnote" id="fnN"><sup>N</sup> …</p>` (Textile 2
//!   "Footnotes"; the Hobix form lacks the classes).

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

    // Pass 1: collect `[alias]url` definition lines from anywhere in the
    // document (both references allow definitions after their uses). A def
    // line is its own block-level unit and never renders (Hobix: "Place the
    // URL anywhere in your document, beginning with its alias in square
    // brackets"; docs/TEXTILE-PARITY.md §7).
    var defs = AliasTable.init(doc.allocator());
    defer defs.deinit();
    try collectAliases(doc, &defs);

    var lines = source.Lines.init(doc.src.bytes);
    var block: ?ActiveBlock = null;
    var lists = std.ArrayList(ListEntry).empty;
    defer lists.deinit(doc.allocator());
    var table: ?TableState = null;
    var code: ?CodeBlockState = null;
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            // An extended `bq..` keeps blank lines: the current paragraph
            // flushes and the blockquote stays open (docs/TEXTILE-PARITY.md
            // §10). An extended `bc..`/`pre..` keeps blank lines as content.
            if (block != null and block.?.extended) {
                try flushQuoteParagraph(doc, &block, &defs);
                continue;
            }
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try closeTable(doc, &table, &defs);
            if (code != null and !code.?.extended) try closeCode(doc, &code);
            if (code != null and code.?.extended) {
                try code.?.lines.append(doc.allocator(), line.contentSpan());
                continue;
            }
            continue;
        }
        // An open single-period `bc.`/`pre.` block owns every following
        // non-blank line, signature-shaped or not (Textile 2: "a block ends
        // with the first blank line encountered"; docs/TEXTILE-PARITY.md §9).
        // An open extended `bc..`/`pre..` owns every line until the next
        // block signature, blank lines included (handled above).
        if (code != null) {
            if (code.?.extended and try trySignature(doc, line)) {
                try closeCode(doc, &code);
                // Fall through: the signature line opens its own block.
            } else {
                try code.?.lines.append(doc.allocator(), line.contentSpan());
                continue;
            }
        }
        // An open table owns every row-shaped line (`|...|` or a
        // modifier-prefixed row); any other line closes it and is handled
        // below as its own block (docs/TEXTILE-PARITY.md §6).
        if (table != null) {
            if (try parseTableRow(doc, line, 0)) |row| {
                try appendTableRow(doc, &table.?, row);
                continue;
            }
            try closeTable(doc, &table, &defs);
        }
        // Def lines disappear everywhere (an open code block claims them as
        // verbatim content above; a def line between table rows closes the
        // table first).
        if (tryParseDef(line) != null) continue;
        // An open extended `bq..` owns every non-signature line; a
        // recognized block signature ends it and is processed below
        // (Textile 2: extended signatures stay active "until the next
        // signature is found").
        if (block != null and block.?.extended) {
            if (try trySignature(doc, line)) {
                try closeBlock(doc, &block, &defs);
                // Fall through: the signature line opens its own block.
            } else {
                try appendBlockContent(doc, &block, .block_quote, &.{}, line.contentSpan(), line.terminatorSpan());
                continue;
            }
        }
        if (try tryExtendedMarker(doc, line)) |esig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try closeTable(doc, &table, &defs);
            try closeCode(doc, &code);
            switch (esig) {
                .quote => |sig| try openExtendedQuote(doc, &block, sig, line.terminatorSpan()),
                .code => |sig| try openCode(doc, &code, sig),
            }
            continue;
        }
        if (try tryCodeMarker(doc, line)) |sig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try closeTable(doc, &table, &defs);
            try openCode(doc, &code, sig);
            continue;
        }
        if (try tryTableSignature(doc, line)) |sig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try openTable(doc, &table, sig.attrs);
            if (sig.row) |row| try appendTableRow(doc, &table.?, row);
            continue;
        }
        if (try parseTableRow(doc, line, 0)) |row| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try openTable(doc, &table, &.{});
            try appendTableRow(doc, &table.?, row);
            continue;
        }
        if (try tryHeading(doc, line)) |heading| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try emitHeading(doc, line, heading, &defs);
            continue;
        }
        if (try tryParagraphMarker(doc, line)) |sig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try appendBlockContent(doc, &block, .paragraph, sig.attrs, sig.content, line.terminatorSpan());
            continue;
        }
        if (try tryBlockQuoteMarker(doc, line)) |sig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try appendBlockContent(doc, &block, .block_quote, sig.attrs, sig.content, line.terminatorSpan());
            continue;
        }
        if (try tryFootnoteMarker(doc, line)) |sig| {
            try closeBlock(doc, &block, &defs);
            closeLists(&lists);
            try appendFootnoteContent(doc, &block, sig, line.terminatorSpan());
            continue;
        }
        if (tryListMarker(line)) |lm| {
            try closeBlock(doc, &block, &defs);
            try appendListItem(doc, &lists, lm, &defs);
            continue;
        }
        // A non-marker text line closes the list tree: list items are single
        // lines, so an unmarked line is a fresh paragraph (docs/TEXTILE-PARITY.md
        // §5, chosen behavior).
        if (lists.items.len > 0) closeLists(&lists);
        const kind: BlockKind = if (block) |active| active.kind else .paragraph;
        try appendBlockContent(doc, &block, kind, &.{}, line.contentSpan(), line.terminatorSpan());
    }
    try closeBlock(doc, &block, &defs);
    closeLists(&lists);
    try closeTable(doc, &table, &defs);
    try closeCode(doc, &code);
}

const BlockKind = enum { paragraph, block_quote };

const ActiveBlock = struct {
    kind: BlockKind,
    start: u32,
    /// Running end of the last content line (updated as lines append).
    end: u32,
    /// Block attributes from the opening signature's modifiers (empty for
    /// unmarked paragraphs).
    attrs: []const document.Attribute = &.{},
    lines: std.ArrayList(LineRef) = .empty,
    /// Extended `bq..`: blank lines separate paragraphs inside one
    /// blockquote instead of ending the block (docs/TEXTILE-PARITY.md §10).
    extended: bool = false,
    /// The already-created blockquote node for an extended `bq..`; null
    /// for single-period blocks, which create their nodes at close.
    quote: ?*document.Node = null,
    /// A `fnN.` footnote block's number; null for ordinary paragraphs. The
    /// close-time paragraph gains `class="footnote" id="fnN"` and a
    /// leading `<sup>N</sup>` (Textile 2 "Footnotes").
    footnote: ?u16 = null,
    /// The `fnN.` marker's span (through the digits), the leading sup's
    /// span.
    footnote_span: source.Span = .{ .start = 0, .end = 0 },

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
    attrs: []const document.Attribute,
    content: source.Span,
    terminator: source.Span,
) ParseError!void {
    if (block.* == null) {
        block.* = .{ .kind = kind, .start = content.start, .end = content.end, .attrs = attrs };
    }
    std.debug.assert(block.*.?.kind == kind);
    block.*.?.end = content.end;
    try block.*.?.lines.append(doc.allocator(), .{
        .content = content,
        .terminator = terminator,
    });
}

fn closeBlock(doc: *document.Document, block: *?ActiveBlock, defs: *const AliasTable) ParseError!void {
    const active = block.* orelse return;
    if (active.extended) {
        // Extended `bq..`: the blockquote already exists; emit the final
        // paragraph from any remaining lines (a block ending right after
        // a blank line has none), then drop the state.
        if (active.lines.items.len > 0) try flushQuoteParagraph(doc, block, defs);
        block.* = null;
        return;
    }
    block.* = null;

    const lines = active.lines.items;
    const span = source.Span{
        .start = active.start,
        .end = active.end,
    };
    var parent = doc.root;
    var para_attrs: []const document.Attribute = active.attrs;
    if (active.kind == .block_quote) {
        // The `bq` signature's attributes belong to the `<blockquote>`;
        // the single inner paragraph is unmarked.
        const quote = try doc.createNode(.block_quote, span, .{ .block_quote = .{ .attrs = active.attrs } });
        try doc.appendChild(doc.root, quote);
        parent = quote;
        para_attrs = &.{};
    }
    const paragraph = try doc.createNode(.paragraph, span, .{ .paragraph = .{ .attrs = para_attrs } });
    try doc.appendChild(parent, paragraph);
    if (active.footnote) |n| {
        // A `fnN.` block opens with the leading footnote number in a plain
        // `<sup>` (Textile 2's `<p class="footnote" id="fn1"><sup>1</sup>
        // …`); only the inline `[N]` reference carries the class.
        var buf: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable; // u16 fits in 16 bytes
        const sup = try doc.createNode(.superscript, active.footnote_span, .none);
        const text = try doc.createNode(.text, active.footnote_span, .{ .text = try doc.allocator().dupe(u8, num) });
        try doc.appendChild(sup, text);
        try doc.appendChild(paragraph, sup);
        // Both references render the sup followed by a space, so the
        // number never collides with the content ("1Down here").
        const space = try doc.createNode(.text, active.footnote_span, .{ .text = " " });
        try doc.appendChild(paragraph, space);
    }

    for (lines, 0..) |ref, i| {
        if (i > 0) {
            // The break before this line covers the previous line's actual
            // terminator, including the full CRLF pair when present.
            const brk = try doc.createNode(.hard_break, lines[i - 1].terminator, .none);
            try doc.appendChild(paragraph, brk);
        }
        try parseInlines(doc, paragraph, ref.content, defs);
    }
}

/// Emits one paragraph from the accumulated lines into the open extended
/// `bq..` blockquote and clears the line buffer. Called on every blank
/// line inside the extended block and once at close. The inner paragraphs
/// are unmarked, like the single inner paragraph of a plain `bq.`.
fn flushQuoteParagraph(doc: *document.Document, block: *?ActiveBlock, defs: *const AliasTable) ParseError!void {
    const active = block.* orelse return;
    const lines = active.lines.items;
    if (lines.len == 0) return;
    const span = source.Span{
        .start = active.start,
        .end = lines[lines.len - 1].content.end,
    };
    const paragraph = try doc.createNode(.paragraph, span, .{ .paragraph = .{} });
    try doc.appendChild(active.quote.?, paragraph);
    for (lines, 0..) |ref, i| {
        if (i > 0) {
            const brk = try doc.createNode(.hard_break, lines[i - 1].terminator, .none);
            try doc.appendChild(paragraph, brk);
        }
        try parseInlines(doc, paragraph, ref.content, defs);
    }
    block.*.?.lines.clearRetainingCapacity();
    block.*.?.quote.?.span.end = span.end;
}

// ---------------------------------------------------------------------------
// Block code (`bc.`) and preformatted text (`pre.`).
//
// A single-period `bc.`/`pre.` signature opens a leaf that owns every
// following non-blank line, verbatim — signature-shaped lines stay code
// content (Textile 2: "a block ends with the first blank line
// encountered"). The extended `bc..`/`pre..` forms keep blank lines as
// content and run until the next block signature (see the extended-blocks
// section below). `bc` is "block code": a preformatted section like `pre`
// that also gets a `<code>` tag, with `<` and `>` translated to HTML
// entities automatically (Textile 2). `pre` is "pre-formatted text"
// (current Textile docs), rendered verbatim inside `<pre>`. Hobix
// documents neither signature (raw HTML only), so both follow the Textile
// 2 + current-docs majority.
// ---------------------------------------------------------------------------

/// The parsed result of a `bc.`/`pre.` signature line.
const CodeSignature = struct {
    /// `pre.` (verbatim `<pre>`) when true; `bc.` (escaped `<pre><code>`)
    /// when false.
    preformatted: bool,
    /// Block-attribute modifiers (`bc{color:red}.`), on the `<pre>`.
    attrs: []const document.Attribute,
    /// Content span after the marker and its separator whitespace.
    content: source.Span,
    /// Extended (`bc..`/`pre..`): blank lines stay content and the block
    /// runs until the next block signature.
    extended: bool = false,
};

/// An open code block: content lines are collected verbatim until a blank
/// line (single-period) or the next block signature (extended), then
/// published as a `.code_block` leaf.
const CodeBlockState = struct {
    preformatted: bool,
    attrs: []const document.Attribute,
    /// The node span: first content line's start through the last line's
    /// content end.
    span: source.Span,
    extended: bool = false,
    lines: std.ArrayList(source.Span) = .empty,
};

/// Recognizes a `bc.` or `pre.` code-block signature with optional block
/// modifiers between the marker and the period. The marker must be followed
/// by a space/tab, and the content must be non-empty (the same conservative
/// rule `bq.` uses: an empty signature's behavior is unspecified, so the
/// line stays literal).
fn tryCodeMarker(doc: *document.Document, line: source.Line) ParseError!?CodeSignature {
    const t = line.text;
    const preformatted = blk: {
        if (t.len >= 3 and t[0] == 'p' and t[1] == 'r' and t[2] == 'e') break :blk true;
        if (t.len >= 2 and t[0] == 'b' and t[1] == 'c') break :blk false;
        return null;
    };
    const mod_start: usize = if (preformatted) 3 else 2;
    if (t.len <= mod_start) return null;
    if (t[mod_start] == '.') {
        if (t.len == mod_start + 1) return null; // marker must be followed by a space/tab
        if (t[mod_start + 1] != ' ' and t[mod_start + 1] != '\t') return null;
        var i = mod_start + 2;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        if (i == t.len) return null; // empty content stays literal
        return .{
            .preformatted = preformatted,
            .attrs = &.{},
            .content = .{
                .start = @intCast(line.start + i),
                .end = @intCast(line.content_end),
            },
        };
    }
    const sig = (try parseBlockSignature(doc, line, mod_start)) orelse return null;
    if (sig.content.start >= sig.content.end) return null;
    return .{
        .preformatted = preformatted,
        .attrs = sig.attrs,
        .content = sig.content,
    };
}

/// Opens a code block with the signature line as its first content line.
fn openCode(doc: *document.Document, code: *?CodeBlockState, sig: CodeSignature) ParseError!void {
    code.* = .{
        .preformatted = sig.preformatted,
        .attrs = sig.attrs,
        .span = .{ .start = sig.content.start, .end = sig.content.end },
        .extended = sig.extended,
    };
    try code.*.?.lines.append(doc.allocator(), sig.content);
}

/// Publishes the collected lines as a `.code_block` leaf. Content is the
/// verbatim lines joined with `\n`, plus one final newline — the shared
/// code-block convention ("one newline for every source content line",
/// docs/DOCUMENT-MODEL.md) — so the same renderer emits Markdown fences
/// and Textile `bc.` identically.
fn closeCode(doc: *document.Document, code: *?CodeBlockState) ParseError!void {
    var active = code.* orelse return;
    code.* = null;
    active.span.end = active.lines.items[active.lines.items.len - 1].end;
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(doc.allocator());
    for (active.lines.items) |span| {
        try content.appendSlice(doc.allocator(), doc.src.bytes[span.start..span.end]);
        try content.append(doc.allocator(), '\n');
    }
    const node = try doc.createNode(.code_block, active.span, .{
        .code_block = .{
            .content = try content.toOwnedSlice(doc.allocator()),
            .info = null,
            .escape = !active.preformatted,
            .attrs = active.attrs,
        },
    });
    try doc.appendChild(doc.root, node);
}

// ---------------------------------------------------------------------------
// Extended blocks (`sig..`).
//
// Two periods in a signature keep it active across blank lines (Textile 2
// "Extended Blocks": "To cause a given block signature to stay active,
// use two periods in your signature instead of one. This will tell Textile
// to keep processing using that signature until it hits the next signature";
// current Textile docs: extended blocks "are terminated with any other text
// block signature"). Oliver implements the three that the references
// discuss: `bq..` (a blockquote of multiple blank-line-separated
// paragraphs), `bc..`, and `pre..` (code with blank lines inside). The
// double period may follow block modifiers (`bq{color:red}..`). List
// markers, table rows, and plain lines are not block signatures, so they
// remain content inside an extended block (docs/TEXTILE-PARITY.md §10).
// ---------------------------------------------------------------------------

/// The parsed result of an extended (`sig..`) block marker.
const ExtendedSig = union(enum) {
    /// `bq..`: opens an extended block quote.
    quote: BlockSignature,
    /// `bc..`/`pre..`: opens an extended code block.
    code: CodeSignature,
};

/// Recognizes an extended block marker: `bq..`, `bc..`, or `pre..`, with
/// optional block modifiers before the double period. The double period
/// must be followed by a space/tab and non-empty content (the same
/// conservative rule the single-period forms use).
fn tryExtendedMarker(doc: *document.Document, line: source.Line) ParseError!?ExtendedSig {
    const t = line.text;
    var is_quote = false;
    var preformatted = false;
    var mod_start: usize = 0;
    if (t.len >= 3 and t[0] == 'b' and t[1] == 'q') {
        is_quote = true;
        mod_start = 2;
    } else if (t.len >= 3 and t[0] == 'b' and t[1] == 'c') {
        mod_start = 2;
    } else if (t.len >= 4 and t[0] == 'p' and t[1] == 'r' and t[2] == 'e') {
        preformatted = true;
        mod_start = 3;
    } else return null;

    var mods = Mods{};
    var dot: usize = 0;
    if (t[mod_start] == '.') {
        dot = mod_start;
    } else {
        const scan = scanMods(t, mod_start, .block) orelse return null;
        if (!scan.dot_terminated) return null;
        mods = scan.mods;
        dot = scan.end;
    }
    if (dot + 2 >= t.len or t[dot + 1] != '.') return null; // need `..`
    if (t[dot + 2] != ' ' and t[dot + 2] != '\t') return null;
    var i = dot + 3;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    if (i == t.len) return null; // empty content stays literal
    const content = source.Span{
        .start = @intCast(line.start + i),
        .end = @intCast(line.content_end),
    };
    const style = try composeStyle(doc, mods.user_style, mods.pad_left, mods.pad_right, halignFragment(mods.halign), mods.valign);
    const attrs = try composeAttrs(doc, style, mods.class, mods.id, mods.lang);
    if (is_quote) return .{ .quote = .{ .attrs = attrs, .content = content } };
    return .{ .code = .{ .preformatted = preformatted, .attrs = attrs, .content = content, .extended = true } };
}

/// Opens an extended `bq..`: the blockquote node is created immediately so
/// paragraphs can be flushed into it at every blank line.
fn openExtendedQuote(doc: *document.Document, block: *?ActiveBlock, sig: BlockSignature, terminator: source.Span) ParseError!void {
    const quote = try doc.createNode(.block_quote, sig.content, .{ .block_quote = .{ .attrs = sig.attrs } });
    try doc.appendChild(doc.root, quote);
    block.* = .{
        .kind = .block_quote,
        .start = sig.content.start,
        .end = sig.content.end,
        .attrs = sig.attrs,
        .extended = true,
        .quote = quote,
    };
    try block.*.?.lines.append(doc.allocator(), .{
        .content = sig.content,
        .terminator = terminator,
    });
}

// ---------------------------------------------------------------------------
// Footnotes (`[N]` references and `fnN.` blocks).
//
// Both references agree on the structure: a `[N]` marker inline becomes a
// superscript link to `#fnN` (Hobix: `<sup><a href="#fn1">1</a></sup>`;
// Textile 2 adds `class="footnote"`), and an `fnN.` paragraph provides
// the footnote's content, rendered with `id="fnN"` and a leading `<sup>`
// (Textile 2 adds `class="footnote"` to the paragraph too). Oliver
// follows the Textile 2 form — the classes are the newer, documented
// rendering and are pinned by the fixtures (docs/TEXTILE-PARITY.md §11).
// ---------------------------------------------------------------------------

/// The parsed result of a `fnN.` footnote signature line.
const FootnoteSig = struct {
    /// The footnote number (the digits between `fn` and the period).
    number: u16,
    /// `class="footnote" id="fnN"` in the fixed render order.
    attrs: []const document.Attribute,
    /// The marker's span: `fn` through the digits (the leading sup's span).
    marker: source.Span,
    /// Content span after the marker and its separator whitespace.
    content: source.Span,
};

/// Recognizes a `fnN.` footnote signature: `fn` + a digit run, optionally
/// followed by the §8 block modifiers (`fn1{color:blue}.`, `fn2>.`), then
/// `.` + a space/tab + non-empty content (Hobix: "begin a new paragraph
/// with fn and the footnote's number, followed by a dot and a space";
/// Textile 2: "You add a number following the fn keyword"). Empty content
/// stays literal, like the other block signatures.
fn tryFootnoteMarker(doc: *document.Document, line: source.Line) ParseError!?FootnoteSig {
    const t = line.text;
    if (t.len < 5) return null;
    if (t[0] != 'f' or t[1] != 'n') return null;
    var k: usize = 2;
    var number: u16 = 0;
    while (k < t.len and t[k] >= '0' and t[k] <= '9') : (k += 1) {
        const d = t[k] - '0';
        if (number > (std.math.maxInt(u16) - @as(u16, d)) / 10) return null;
        number = number * 10 + d;
    }
    if (k == 2) return null; // a digit run is required

    var buf: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "fn{d}", .{number}) catch unreachable; // u16 fits
    var attrs: []const document.Attribute = undefined;
    var content: source.Span = undefined;
    if (t[k] == '.') {
        if (k + 1 >= t.len or (t[k + 1] != ' ' and t[k + 1] != '\t')) return null;
        var i = k + 2;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        if (i == t.len) return null; // empty content stays literal
        attrs = try composeAttrs(doc, null, "footnote", try doc.allocator().dupe(u8, id), null);
        content = .{ .start = @intCast(line.start + i), .end = @intCast(line.content_end) };
    } else {
        const sig = (try parseBlockSignature(doc, line, k)) orelse return null;
        if (sig.content.start >= sig.content.end) return null;
        // The structural class/id always win; user modifiers contribute
        // their style and lang (the renderer writes attrs in order, so a
        // user class/id would otherwise duplicate the structural ones).
        var list = std.ArrayList(document.Attribute).empty;
        errdefer list.deinit(doc.allocator());
        try list.append(doc.allocator(), .{ .name = "class", .value = try doc.allocator().dupe(u8, "footnote") });
        try list.append(doc.allocator(), .{ .name = "id", .value = try doc.allocator().dupe(u8, id) });
        for (sig.attrs) |a| {
            if (std.mem.eql(u8, a.name, "style") or std.mem.eql(u8, a.name, "lang"))
                try list.append(doc.allocator(), a); // arena-owned already
        }
        attrs = try list.toOwnedSlice(doc.allocator());
        content = sig.content;
    }
    return .{
        .number = number,
        .attrs = attrs,
        .marker = .{ .start = @intCast(line.start), .end = @intCast(line.start + k) },
        .content = content,
    };
}

/// Opens a `fnN.` footnote block: a paragraph whose close-time payload
/// carries `class="footnote" id="fnN"` plus a leading superscript number.
fn appendFootnoteContent(doc: *document.Document, block: *?ActiveBlock, sig: FootnoteSig, terminator: source.Span) ParseError!void {
    block.* = .{
        .kind = .paragraph,
        .start = sig.content.start,
        .end = sig.content.end,
        .attrs = sig.attrs,
        .footnote = sig.number,
        .footnote_span = sig.marker,
    };
    try block.*.?.lines.append(doc.allocator(), .{
        .content = sig.content,
        .terminator = terminator,
    });
}

/// True when the line opens any recognized block-level construct that
/// terminates an open extended block (Textile 2: extended signatures stay
/// active "until the next signature is found"): a `table<mods>.`
/// signature, an extended or single-period `bq.`/`bc.`/`pre.` signature,
/// an `hN.` heading, a `p.` paragraph marker, or a `fnN.` footnote
/// signature. List markers and table rows are not block signatures and
/// remain content inside an extended block.
fn trySignature(doc: *document.Document, line: source.Line) ParseError!bool {
    if (try tryTableSignature(doc, line) != null) return true;
    if (try tryExtendedMarker(doc, line) != null) return true;
    if (try tryHeading(doc, line) != null) return true;
    if (try tryParagraphMarker(doc, line) != null) return true;
    if (try tryBlockQuoteMarker(doc, line) != null) return true;
    if (try tryCodeMarker(doc, line) != null) return true;
    if (try tryFootnoteMarker(doc, line) != null) return true;
    return false;
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
fn appendListItem(doc: *document.Document, lists: *std.ArrayList(ListEntry), lm: ListMarker, defs: *const AliasTable) ParseError!void {
    while (lists.items.len > 0 and lists.items[lists.items.len - 1].depth > lm.depth) {
        _ = lists.pop();
    }
    if (lists.items.len > 0 and lists.items[lists.items.len - 1].depth == lm.depth) {
        const top = &lists.items[lists.items.len - 1];
        if (top.marker == lm.marker) {
            try appendSiblingItem(doc, lists, lm, defs);
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
        const para = try doc.createNode(.paragraph, lm.content, .{ .paragraph = .{} });
        try doc.appendChild(item, para);
        // Only the deepest item carries this line's content; intermediate
        // levels created by a depth jump get an empty item.
        if (depth == lm.depth) try parseInlines(doc, para, lm.content, defs);
        try lists.append(doc.allocator(), .{ .depth = depth, .marker = lm.marker, .list = list, .item = item });
    }
}

/// Adds a sibling item to the open list at `lm.depth` (same marker char) and
/// extends the list span to cover the new item's content.
fn appendSiblingItem(doc: *document.Document, lists: *std.ArrayList(ListEntry), lm: ListMarker, defs: *const AliasTable) ParseError!void {
    const top = &lists.items[lists.items.len - 1];
    top.list.span.end = lm.content.end;
    const item = try doc.createNode(.list_item, lm.content, .none);
    try doc.appendChild(top.list, item);
    const para = try doc.createNode(.paragraph, lm.content, .{ .paragraph = .{} });
    try doc.appendChild(item, para);
    try parseInlines(doc, para, lm.content, defs);
    top.item = item;
}

/// Closes every open list. The nodes are already in the tree; only the
/// reconciliation stack is dropped.
fn closeLists(lists: *std.ArrayList(ListEntry)) void {
    lists.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tables.
//
// A table is its own block: consecutive row lines compose one table until a
// blank line or any other block-level line. Rows are `|a|b|` lines (with an
// optional leading modifier run: `_` header, `<`/`>`/`=`/`<>` alignment,
// `^`/`~` valign, `{style}`, `(class#id)`, `[lang]`, `(`/`)` padding — row
// modifiers end at the first `|` per Textile 2 or after `. ` per Hobix). An
// optional `table<mods>.` signature opens the table (Hobix: alone on its
// own line; Textile 2: followed by the first row). Cell modifiers follow
// the same tokens plus `\n` colspan and `/n` rowspan, and must be
// terminated by a period followed by a space (the documented contract);
// every other shape keeps the whole cell verbatim. Alignment propagates:
// a header cell's alignment becomes the default for the cells below it in
// the same column (Textile 2), resolved at close time when the whole table
// is visible. Cells render as flat `<tr>` rows — the references show no
// thead/tbody (docs/TEXTILE-PARITY.md §7).
// ---------------------------------------------------------------------------

/// The open table block: parsed rows are held until close so the
/// alignment-propagation pass can see the whole table before any cell
/// style resolves.
const TableState = struct {
    /// Table-level attributes from a `table<mods>.` signature.
    attrs: []const document.Attribute,
    rows: std.ArrayList(TableRow) = .empty,
    /// Column count (cell-colspan sum over the widest row): the metadata
    /// length of `table.alignment`.
    col_count: u32 = 0,
};

/// One parsed (but not yet emitted) table row.
const TableRow = struct {
    /// Full line span.
    span: source.Span,
    /// Row-level `_` modifier: every cell is a header cell.
    header: bool,
    /// Row attributes (composed at parse time; the row style needs no
    /// propagation).
    attrs: []const document.Attribute,
    cells: std.ArrayList(TableCellInfo) = .empty,
};

/// One parsed cell. Modifier pieces are kept separate so close time can
/// resolve the propagated horizontal alignment and compose the final
/// style string once.
const TableCellInfo = struct {
    /// Content span (after the modifier terminator), the cell node's span.
    content: source.Span,
    header: bool = false,
    colspan: u8 = 1,
    rowspan: u8 = 1,
    /// Explicit horizontal alignment modifier (`<`, `>`, `=`, `<>`).
    halign: document.TableAlign = .none,
    /// `vertical-align:top` / `vertical-align:bottom` style fragment.
    valign: ?[]const u8 = null,
    user_style: ?[]const u8 = null,
    class: ?[]const u8 = null,
    id: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    pad_left: u8 = 0,
    pad_right: u8 = 0,
};

/// The parsed result of a `table<mods>.` signature line.
const TableSignature = struct {
    attrs: []const document.Attribute,
    /// The first row when the signature line carries one (Textile 2 form).
    row: ?TableRow,
};

/// A run of recognized table modifier tokens.
const Mods = struct {
    header: bool = false,
    colspan: u8 = 1,
    rowspan: u8 = 1,
    halign: document.TableAlign = .none,
    valign: ?[]const u8 = null,
    user_style: ?[]const u8 = null,
    class: ?[]const u8 = null,
    id: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    pad_left: u8 = 0,
    pad_right: u8 = 0,
};

const ModKind = enum { signature, row, cell, block };

/// A successful modifier scan.
const ModScan = struct {
    mods: Mods,
    /// Offset just past the last token: at the `.` of a dot-terminated run
    /// or at the `|` of a pipe-terminated row run.
    end: usize,
    dot_terminated: bool,
};

/// Recognizes one run of table/block modifier tokens starting at `i`:
/// `{style}`, `(class#id)`, `[lang]`, `(`/`)` padding, `<`, `>`, `=`,
/// cell/block-only `<>`, row/cell-only `^`/`~`/`_`, and cell-only `\n`
/// colspan / `/n` rowspan. Returns null when any token is malformed or not
/// allowed in the context, so the whole line stays literal. The run ends at
/// the first `.` (dot-terminated; the caller checks the required following
/// whitespace) or, for rows, directly at a `|` (Textile 2's no-period form).
fn scanMods(bytes: []const u8, i: usize, kind: ModKind) ?ModScan {
    var m = Mods{};
    var j = i;
    while (j < bytes.len) {
        switch (bytes[j]) {
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, bytes, j + 1, '}') orelse return null;
                if (close == j + 1) return null;
                m.user_style = bytes[j + 1 .. close];
                j = close + 1;
            },
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, bytes, j + 1, ']') orelse return null;
                if (close == j + 1) return null;
                m.lang = bytes[j + 1 .. close];
                j = close + 1;
            },
            '(' => {
                // A `(` directly before `(`, `)`, the modifier terminator
                // (`.`, or `|` for rows), or end of line is padding (Hobix:
                // each `(` adds 1em of left padding, `p(.` needs no closing
                // paren); otherwise it opens a `(class#id)` spec terminated
                // by `)`.
                if (j + 1 >= bytes.len or bytes[j + 1] == '(' or bytes[j + 1] == ')' or bytes[j + 1] == '.' or (kind == .row and bytes[j + 1] == '|')) {
                    m.pad_left += 1;
                    j += 1;
                } else {
                    const close = std.mem.indexOfScalarPos(u8, bytes, j + 1, ')') orelse return null;
                    if (close == j + 1) return null;
                    const inner = bytes[j + 1 .. close];
                    if (std.mem.indexOfScalar(u8, inner, '#')) |h| {
                        m.class = inner[0..h];
                        m.id = inner[h + 1 ..];
                    } else {
                        m.class = inner;
                    }
                    j = close + 1;
                }
            },
            ')' => {
                m.pad_right += 1;
                j += 1;
            },
            '<' => {
                if (j + 1 < bytes.len and bytes[j + 1] == '>') {
                    if (kind != .cell and kind != .block) return null; // `<>` is cells/blocks-only
                    m.halign = .justify;
                    j += 2;
                } else {
                    m.halign = .left;
                    j += 1;
                }
            },
            '>' => {
                m.halign = .right;
                j += 1;
            },
            '=' => {
                m.halign = .center;
                j += 1;
            },
            '^' => {
                if (kind != .cell and kind != .row) return null;
                m.valign = "vertical-align:top";
                j += 1;
            },
            '~' => {
                if (kind != .cell and kind != .row) return null;
                m.valign = "vertical-align:bottom";
                j += 1;
            },
            '_' => {
                if (kind != .cell and kind != .row) return null;
                m.header = true;
                j += 1;
            },
            '\\' => {
                if (kind != .cell) return null;
                const n = scanSpanNumber(bytes, j + 1) orelse return null;
                m.colspan = n;
                j += 1 + decimalDigits(bytes, j + 1);
            },
            '/' => {
                if (kind != .cell) return null;
                const n = scanSpanNumber(bytes, j + 1) orelse return null;
                m.rowspan = n;
                j += 1 + decimalDigits(bytes, j + 1);
            },
            else => return null,
        }
        if (j >= bytes.len) return null; // the run must end at `.` or `|`
        if (bytes[j] == '.') return .{ .mods = m, .end = j, .dot_terminated = true };
        if (kind == .row and bytes[j] == '|') return .{ .mods = m, .end = j, .dot_terminated = false };
    }
    return null;
}

/// Reads the span number after a `\`/`/` colspan/rowspan token. A missing,
/// zero, or oversized span is rejected (the cell stays literal).
fn scanSpanNumber(bytes: []const u8, i: usize) ?u8 {
    if (i >= bytes.len) return null;
    var n: u8 = 0;
    var k = i;
    while (k < bytes.len and bytes[k] >= '0' and bytes[k] <= '9') : (k += 1) {
        n = n *% 10 +% (bytes[k] - '0');
    }
    if (k == i or n == 0 or n > 20) return null;
    return n;
}

fn decimalDigits(bytes: []const u8, i: usize) usize {
    var k = i;
    while (k < bytes.len and bytes[k] >= '0' and bytes[k] <= '9') : (k += 1) {}
    return k - i;
}

/// The first byte of a cell that could open a modifier run.
fn isCellModifierStart(b: u8) bool {
    return switch (b) {
        '_', '<', '>', '=', '^', '~', '\\', '/', '{', '(', ')', '[' => true,
        else => false,
    };
}

/// Parses one row line starting at byte `start` of the line (a plain `|`
/// row, or a modifier-prefixed row). A row must start with `|` (after any
/// modifiers) and end with `|`; every `|` splits (Textile has no pipe
/// escape). Returns null when the line is not a row.
fn parseTableRow(doc: *document.Document, line: source.Line, start: usize) ParseError!?TableRow {
    const t = line.text;
    var i = start;
    var mods = Mods{};
    if (i < t.len and t[i] != '|') {
        const scan = scanMods(t, i, .row) orelse return null;
        mods = scan.mods;
        if (scan.dot_terminated) {
            if (scan.end + 1 >= t.len or !isWhitespaceByte(t[scan.end + 1])) return null;
            i = scan.end + 2;
        } else {
            i = scan.end;
        }
        if (i >= t.len or t[i] != '|') return null;
    }
    if (i >= t.len or t[i] != '|') return null;
    const end = t.len;
    if (end <= i + 1 or t[end - 1] != '|') return null;

    const row_style = try composeStyle(doc, mods.user_style, mods.pad_left, mods.pad_right, halignFragment(mods.halign), mods.valign);
    const row_attrs = try composeAttrs(doc, row_style, mods.class, mods.id, mods.lang);
    var row = TableRow{
        .span = line.contentSpan(),
        .header = mods.header,
        .attrs = row_attrs,
        .cells = std.ArrayList(TableCellInfo).empty,
    };
    errdefer row.cells.deinit(doc.allocator());
    var seg_start = i + 1;
    var seg = seg_start;
    while (seg < end) : (seg += 1) {
        if (t[seg] == '|') {
            try row.cells.append(doc.allocator(), try parseCell(doc, line, seg_start, seg));
            seg_start = seg + 1;
        }
    }
    return row;
}

/// Parses one cell segment `[start, end)` of the line: optional modifiers
/// terminated by `. ` (the documented contract: "a period followed with a
/// space"), then verbatim content. Every other shape — no modifiers,
/// malformed modifiers, or a terminator without the space — keeps the whole
/// segment as content.
fn parseCell(doc: *document.Document, line: source.Line, start: usize, end: usize) ParseError!TableCellInfo {
    _ = doc;
    const t = line.text;
    var content_start = start;
    var mods = Mods{};
    if (start < end and isCellModifierStart(t[start])) {
        if (scanMods(t, start, .cell)) |scan| {
            if (scan.dot_terminated and scan.end + 1 < end and isWhitespaceByte(t[scan.end + 1])) {
                mods = scan.mods;
                content_start = scan.end + 2;
            }
        }
    }
    return .{
        .content = .{
            .start = @intCast(line.start + content_start),
            .end = @intCast(line.start + end),
        },
        .header = mods.header,
        .colspan = mods.colspan,
        .rowspan = mods.rowspan,
        .halign = mods.halign,
        .valign = mods.valign,
        .user_style = mods.user_style,
        .class = mods.class,
        .id = mods.id,
        .lang = mods.lang,
        .pad_left = mods.pad_left,
        .pad_right = mods.pad_right,
    };
}

/// Recognizes a `table<mods>.` signature. The signature is `table` plus
/// optional modifiers terminated by a period (Hobix puts the period at end
/// of line; Textile 2 follows it with a space and the first row). When text
/// follows the period it must parse as a row, or the line is not a
/// signature at all (conservative: `table. of contents` stays a paragraph,
/// docs/TEXTILE-PARITY.md §7).
fn tryTableSignature(doc: *document.Document, line: source.Line) ParseError!?TableSignature {
    const t = line.text;
    if (t.len < 6) return null;
    if (!std.mem.eql(u8, t[0..5], "table")) return null;
    var i: usize = 5;
    var mods = Mods{};
    if (i < t.len and t[i] != '.') {
        const scan = scanMods(t, i, .signature) orelse return null;
        mods = scan.mods;
        if (!scan.dot_terminated) return null;
        i = scan.end;
    }
    if (i >= t.len or t[i] != '.') return null;
    i += 1;
    const style = try composeStyle(doc, mods.user_style, mods.pad_left, mods.pad_right, tableHalignFragment(mods.halign), null);
    const attrs = try composeAttrs(doc, style, mods.class, mods.id, mods.lang);
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    if (i == t.len) return .{ .attrs = attrs, .row = null };
    const row = (try parseTableRow(doc, line, i)) orelse return null;
    return .{ .attrs = attrs, .row = row };
}

fn openTable(doc: *document.Document, table: *?TableState, attrs: []const document.Attribute) ParseError!void {
    _ = doc;
    std.debug.assert(table.* == null);
    table.* = .{ .attrs = attrs };
}

fn appendTableRow(doc: *document.Document, table: *TableState, row: TableRow) ParseError!void {
    var cols: u32 = 0;
    for (row.cells.items) |c| cols += c.colspan;
    if (cols > table.col_count) table.col_count = cols;
    try table.rows.append(doc.allocator(), row);
}

/// Closes an open table: resolves the column-alignment defaults (Textile 2
/// header-propagation rule), then emits the table, rows, and cells into the
/// model. A signature that never received a row produces no table (tables
/// must be in their own block; docs/TEXTILE-PARITY.md §7).
fn closeTable(doc: *document.Document, table: *?TableState, defs: *const AliasTable) ParseError!void {
    var state = table.* orelse return;
    table.* = null;
    defer deinitTableState(doc.allocator(), &state);
    if (state.rows.items.len == 0) return;

    // Textile 2: "When a cell is identified as a header cell and an
    // alignment is specified, that becomes the default alignment for cells
    // below it." Walking top-down, a header cell with an explicit
    // alignment updates its column's default; every other cell inherits the
    // current default unless it carries its own alignment. Only horizontal
    // alignment propagates (`^`/`~` vertical stays per-cell).
    const defaults = try doc.allocator().alloc(document.TableAlign, state.col_count);
    @memset(defaults, .none);
    for (state.rows.items) |*row| {
        var col: u32 = 0;
        for (row.cells.items) |*cell| {
            if (col < state.col_count and cell.header and cell.halign != .none) defaults[col] = cell.halign;
            col += cell.colspan;
        }
    }

    const first = &state.rows.items[0];
    const last = &state.rows.items[state.rows.items.len - 1];
    const table_node = try doc.createNode(.table, .{
        .start = first.span.start,
        .end = last.span.end,
    }, .{
        .table = .{
            .alignment = defaults,
            .attrs = state.attrs,
            .sections = false,
        },
    });
    try doc.appendChild(doc.root, table_node);

    for (state.rows.items) |*row| {
        const row_node = try doc.createNode(.table_row, row.span, .{ .table_row = .{ .attrs = row.attrs } });
        try doc.appendChild(table_node, row_node);
        var col: u32 = 0;
        for (row.cells.items) |*cell| {
            const resolved = if (cell.halign != .none) cell.halign else if (col < state.col_count) defaults[col] else .none;
            const style = try composeStyle(doc, cell.user_style, cell.pad_left, cell.pad_right, halignFragment(resolved), cell.valign);
            const attrs = try composeAttrs(doc, style, cell.class, cell.id, cell.lang);
            const cell_node = try doc.createNode(.table_cell, cell.content, .{
                .table_cell = .{
                    // A row-level `_` marks every cell of the row as a
                    // header cell (Textile 2: "header row or cell").
                    .header = row.header or cell.header,
                    // Textile alignment lives in the cell's `style`;
                    // `alignment` (the GFM `align` attribute) stays none.
                    .alignment = .none,
                    .colspan = cell.colspan,
                    .rowspan = cell.rowspan,
                    .attrs = attrs,
                },
            });
            try doc.appendChild(row_node, cell_node);
            try parseInlines(doc, cell_node, cell.content, defs);
            col += cell.colspan;
        }
    }
}

fn deinitTableState(allocator: std.mem.Allocator, state: *TableState) void {
    for (state.rows.items) |*row| row.cells.deinit(allocator);
    state.rows.deinit(allocator);
}

/// The horizontal-alignment style fragment for a cell or row.
fn halignFragment(a: document.TableAlign) ?[]const u8 {
    return switch (a) {
        .none => null,
        .left => "text-align:left",
        .right => "text-align:right",
        .center => "text-align:center",
        .justify => "text-align:justify",
    };
}

/// The table-signature alignment fragment (Textile 2: `<`/`>` float the
/// table, `=` centers it via auto side margins).
fn tableHalignFragment(a: document.TableAlign) ?[]const u8 {
    return switch (a) {
        .none => null,
        .left => "float:left",
        .right => "float:right",
        .center => "margin-left:auto;margin-right:auto",
        .justify => null, // `<>` is cells-only and never reaches here
    };
}

/// Appends one CSS rule to a composed style, joining with `; ` (Hobix:
/// `color:red; padding-left:1em; text-align:right;`). Empty rules are
/// skipped.
fn appendStyleRule(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rule: []const u8) ParseError!void {
    if (rule.len == 0) return;
    if (out.items.len > 0) try out.appendSlice(allocator, "; ");
    try out.appendSlice(allocator, rule);
}

/// Composes a Textile style string from its parts in the pinned order:
/// user `{style}`, padding-left, padding-right, horizontal alignment, then
/// vertical alignment — joined with `; ` and terminated with `;` (Hobix
/// examples; docs/TEXTILE-PARITY.md §7). Empty when no part applies. A
/// multi-declaration user style is normalized the way Hobix renders it:
/// `{color:blue;margin:30px}` becomes `color:blue; margin:30px` (internal
/// `;` grows a trailing space; a trailing `;` is dropped).
fn composeStyle(
    doc: *document.Document,
    user_style: ?[]const u8,
    pad_left: u8,
    pad_right: u8,
    halign_frag: ?[]const u8,
    valign: ?[]const u8,
) ParseError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(doc.allocator());
    if (user_style) |s| {
        if (std.mem.indexOfScalar(u8, s, ';') == null) {
            try appendStyleRule(doc.allocator(), &out, s);
        } else {
            var start: usize = 0;
            while (start < s.len) {
                const semi = std.mem.indexOfScalarPos(u8, s, start, ';') orelse break;
                if (semi > start) try appendStyleRule(doc.allocator(), &out, s[start..semi]);
                start = semi + 1;
            }
            if (start < s.len) try appendStyleRule(doc.allocator(), &out, s[start..]);
        }
    }
    if (pad_left > 0) try appendStyleRule(doc.allocator(), &out, try std.fmt.allocPrint(doc.allocator(), "padding-left:{d}em", .{pad_left}));
    if (pad_right > 0) try appendStyleRule(doc.allocator(), &out, try std.fmt.allocPrint(doc.allocator(), "padding-right:{d}em", .{pad_right}));
    if (halign_frag) |f| try appendStyleRule(doc.allocator(), &out, f);
    if (valign) |v| try appendStyleRule(doc.allocator(), &out, v);
    if (out.items.len == 0) return "";
    try out.append(doc.allocator(), ';');
    return out.items;
}

/// Composes the fixed render-order attribute list (style, class, id, lang)
/// with arena-owned copies (Textile normalizes the values, so they cannot
/// borrow the source; docs/DOCUMENT-MODEL.md). Empty class/id values are
/// omitted — a `(#id)`-only spec renders just the id attribute (Hobix).
fn composeAttrs(
    doc: *document.Document,
    style: ?[]const u8,
    class: ?[]const u8,
    id: ?[]const u8,
    lang: ?[]const u8,
) ParseError![]const document.Attribute {
    var list = std.ArrayList(document.Attribute).empty;
    errdefer list.deinit(doc.allocator());
    if (style) |s| {
        if (s.len > 0) try list.append(doc.allocator(), .{ .name = "style", .value = try doc.allocator().dupe(u8, s) });
    }
    if (class) |c| {
        if (c.len > 0) try list.append(doc.allocator(), .{ .name = "class", .value = try doc.allocator().dupe(u8, c) });
    }
    if (id) |i| {
        if (i.len > 0) try list.append(doc.allocator(), .{ .name = "id", .value = try doc.allocator().dupe(u8, i) });
    }
    if (lang) |l| try list.append(doc.allocator(), .{ .name = "lang", .value = try doc.allocator().dupe(u8, l) });
    return list.toOwnedSlice(doc.allocator());
}

/// The parsed result of a block signature line (`p<mods>.`, `bq<mods>.`,
/// `hN<mods>.`): the composed block attributes and the content span after
/// the marker's separator whitespace.
const BlockSignature = struct {
    attrs: []const document.Attribute,
    content: source.Span,
};

/// Scans the modifier run between a block marker and its period (`{style}`,
/// `(class#id)`, `[lang]`, `(`/`)` padding, `<`/`>`/`=`/`<>` alignment),
/// composes the block attributes, and returns the content span after the
/// period and its separator whitespace. Malformed modifiers, or a period
/// not followed by a space/tab, make the whole line ordinary text.
fn parseBlockSignature(doc: *document.Document, line: source.Line, mod_start: usize) ParseError!?BlockSignature {
    const t = line.text;
    const scan = scanMods(t, mod_start, .block) orelse return null;
    if (!scan.dot_terminated) return null;
    if (scan.end + 1 >= t.len or !isWhitespaceByte(t[scan.end + 1])) return null;
    var i = scan.end + 2;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
    const style = try composeStyle(doc, scan.mods.user_style, scan.mods.pad_left, scan.mods.pad_right, halignFragment(scan.mods.halign), scan.mods.valign);
    const attrs = try composeAttrs(doc, style, scan.mods.class, scan.mods.id, scan.mods.lang);
    return .{
        .attrs = attrs,
        .content = .{
            .start = @intCast(line.start + i),
            .end = @intCast(line.content_end),
        },
    };
}

const Heading = struct {
    level: u8,
    /// Block attributes from the marker's modifiers (empty for plain `hN.`).
    attrs: []const document.Attribute = &.{},
    /// Content span (after the marker and its separator whitespace).
    content: source.Span,
};

/// Recognizes `h1.`–`h6.` block markers, with optional block modifiers
/// between the level digit and the period (`h2()>.`, `h3[no]{color:red}.`,
/// Hobix §4). The marker must be followed by a space or tab (both
/// references require a space after the signature's period). Content is
/// everything after the marker's separator whitespace, preserved verbatim.
fn tryHeading(doc: *document.Document, line: source.Line) ParseError!?Heading {
    const t = line.text;
    if (t.len < 3) return null;
    if (t[0] != 'h') return null;
    const digit = t[1];
    if (digit < '1' or digit > '6') return null;
    if (t[2] == '.') {
        if (t.len == 3) return null; // marker must be followed by a space/tab
        if (t[3] != ' ' and t[3] != '\t') return null;
        var i: usize = 3;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        return .{
            .level = digit - '0',
            .attrs = &.{},
            .content = .{
                .start = @intCast(line.start + i),
                .end = @intCast(line.content_end),
            },
        };
    }
    const sig = (try parseBlockSignature(doc, line, 2)) orelse return null;
    return .{
        .level = digit - '0',
        .attrs = sig.attrs,
        .content = sig.content,
    };
}

/// Recognizes a `p.` paragraph marker (with optional block modifiers between
/// the `p` and the period), returning the composed block attributes and the
/// content span after the marker and its separator whitespace. `p.` without a
/// following space/tab, or a malformed modifier run, is ordinary text.
fn tryParagraphMarker(doc: *document.Document, line: source.Line) ParseError!?BlockSignature {
    const t = line.text;
    if (t.len < 3) return null;
    if (t[0] != 'p') return null;
    if (t[1] == '.') {
        if (t[2] != ' ' and t[2] != '\t') return null;
        var i: usize = 2;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        return .{
            .attrs = &.{},
            .content = .{
                .start = @intCast(line.start + i),
                .end = @intCast(line.content_end),
            },
        };
    }
    return parseBlockSignature(doc, line, 1);
}

/// Recognizes the single-period `bq.` block-quote signature (with optional
/// block modifiers: `bq{color:red}.`, `bq>.`, ...). Published Textile
/// documentation requires a period followed by a space; Oliver consistently
/// accepts a tab as signature separator too. An empty content range is not a
/// quote: empty `bq.` behavior is unspecified by the documentation, so the
/// whole line remains literal. This also deliberately excludes the separately
/// documented extended (`bq..`) and citation (`bq.:URL`) forms.
fn tryBlockQuoteMarker(doc: *document.Document, line: source.Line) ParseError!?BlockSignature {
    const t = line.text;
    if (t.len < 4) return null;
    if (!std.mem.eql(u8, t[0..2], "bq")) return null;
    if (t[2] == '.') {
        if (t[3] != ' ' and t[3] != '\t') return null;
        var i: usize = 3;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        if (i == t.len) return null;
        return .{
            .attrs = &.{},
            .content = .{
                .start = @intCast(line.start + i),
                .end = @intCast(line.content_end),
            },
        };
    }
    const sig = (try parseBlockSignature(doc, line, 2)) orelse return null;
    if (sig.content.start >= sig.content.end) return null;
    return sig;
}

fn emitHeading(doc: *document.Document, line: source.Line, heading: Heading, defs: *const AliasTable) ParseError!void {
    const node = try doc.createNode(.heading, line.contentSpan(), .{
        .heading = .{ .level = heading.level, .attrs = heading.attrs },
    });
    try doc.appendChild(doc.root, node);
    try parseInlines(doc, node, heading.content, defs);
}

// ---------------------------------------------------------------------------
// Link aliases.
//
// Both references document `[alias]url` definition blocks (Textile 2: "place
// one or more links in a block of it's own, anywhere within your document")
// and `"text":alias` references. Definitions are collected in a first pass
// so a use may precede its definition (Hobix's example defines `hobix` after
// using it), and a def line disappears from output. An alias is the shortest
// run up to the first `]`; the URL is the whole rest of the line, verbatim,
// with no whitespace. The first definition of an alias wins; matching is
// exact and case-sensitive (the references are silent on folding, so the
// conservative choice is pinned in docs/TEXTILE-PARITY.md §7).
// ---------------------------------------------------------------------------

/// `[alias]url` definitions: alias name → absolute source span of its URL.
/// Keys are source slices (valid for the whole parse); lookups are O(1).
const AliasTable = std.StringHashMap(source.Span);

/// One recognized `[alias]url` definition line.
const DefLine = struct {
    /// The alias bytes (between the brackets), a source slice.
    alias: []const u8,
    /// Absolute span of the URL (the whole rest of the line).
    url: source.Span,
};

/// Recognizes a definition line: `[` + non-empty alias without `[` + `]` +
/// a non-whitespace URL to end of line. Any other shape — `[1] See this`,
/// `[]http://x`, `[x]`, `[a[b]url` — is ordinary text. A def line needs no
/// blank-line separation (Hobix's definition directly follows the
/// paragraph): the line vanishes from output without changing the
/// surrounding block — an open paragraph or list continues across it, per
/// "place the URL anywhere in your document".
fn tryParseDef(line: source.Line) ?DefLine {
    const t = line.text;
    if (t.len < 4 or t[0] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, t, 1, ']') orelse return null;
    if (close == 1) return null; // empty alias
    const alias = t[1..close];
    if (std.mem.indexOfScalar(u8, alias, '[') != null) return null;
    if (close + 1 >= t.len or isWhitespaceByte(t[close + 1])) return null;
    const url = t[close + 1 ..];
    for (url) |b| {
        if (isWhitespaceByte(b)) return null;
    }
    return .{
        .alias = alias,
        .url = .{
            .start = @intCast(line.start + close + 1),
            .end = @intCast(line.content_end),
        },
    };
}

/// Pass 1: walks every line and records `[alias]url` definitions. The first
/// definition of an alias wins (deterministic, mirroring the Markdown §4.7
/// first-definition-wins machinery).
fn collectAliases(doc: *document.Document, defs: *AliasTable) ParseError!void {
    var lines = source.Lines.init(doc.src.bytes);
    while (lines.next()) |line| {
        const def = tryParseDef(line) orelse continue;
        if (!defs.contains(def.alias)) {
            try defs.put(def.alias, def.url);
        }
    }
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
    /// The URL token after the colon (a direct URL, or the alias name when
    /// `alias_href` is set).
    href: Range,
    /// Absolute source span of the alias's defined URL when `href` names a
    /// `[alias]url` definition; null for a direct URL.
    alias_href: ?source.Span = null,
    title: ?Range,
};

const ImageData = struct {
    span: Range,
    src: Range,
    alt: ?Range,
    link_href: ?Range,
};

/// A `[N]` footnote reference (Textile 2 "Footnotes").
const FootnoteRefData = struct {
    /// Full construct: `[` through `]` (relative offsets).
    span: Range,
    number: u16,
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
    footnote: FootnoteRefData,
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
/// the pass stays linear. `defs` resolves `"text":alias` references; each
/// lookup is O(1), so the pass stays linear.
fn scanLineItems(doc: *document.Document, items: *std.ArrayList(InlineItem), content: source.Span, defs: *const AliasTable) ParseError!void {
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
                if (scanLink(doc, bytes, i, defs)) |link| {
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
            if (b == '[') {
                if (scanFootnoteRef(bytes, i)) |ref| {
                    try appendTextItem(doc.allocator(), items, run_start, i);
                    try items.append(doc.allocator(), .{ .footnote = ref });
                    run_start = ref.span.end;
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
/// when preceded by a space. When the URL token names a defined alias, the
/// link resolves through `defs` (Hobix "Link Aliases"; Textile 2) — the
/// token's own bytes become metadata only and the defined URL is the href.
/// Returns null (the `"` stays literal text) for any shape the references
/// do not define; see docs/TEXTILE-PARITY.md §5.
fn scanLink(doc: *const document.Document, bytes: []const u8, i: usize, defs: *const AliasTable) ?LinkData {
    _ = doc;
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
        .alias_href = defs.get(bytes[url_start..url_end]),
        .title = title,
    };
}

/// Recognizes a `[N]` footnote reference: `[` + at least one digit + `]`
/// (Hobix "Footnotes"; Textile 2 "Footnotes": "the brackets with a number
/// inside"). Any other bracketed shape stays literal text. Multi-digit
/// numbers are allowed; numbers beyond `u16` stay literal (conservative).
fn scanFootnoteRef(bytes: []const u8, i: usize) ?FootnoteRefData {
    var j = i + 1;
    var number: u16 = 0;
    while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') : (j += 1) {
        const d = bytes[j] - '0';
        if (number > (std.math.maxInt(u16) - @as(u16, d)) / 10) return null;
        number = number * 10 + d;
    }
    if (j == i + 1) return null; // at least one digit
    if (j >= bytes.len or bytes[j] != ']') return null;
    return .{ .span = .{ .start = i, .end = j + 1 }, .number = number };
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
                    // An alias-resolved link's href lives at the definition's
                    // URL span elsewhere in the document, not in this line.
                    const href_slice = if (l.alias_href) |abs| doc.text(abs) else bytesOf(doc, content, l.href);
                    const link = try doc.createNode(.link, subSpan(content, l.span.start, l.span.end), .{
                        .link = .{
                            .href = try doc.allocator().dupe(u8, href_slice),
                            .title = if (l.title) |t| try doc.allocator().dupe(u8, bytesOf(doc, content, t)) else null,
                        },
                    });
                    try doc.appendChild(scope.parent, link);
                    const display = subSpan(content, l.display.start, l.display.end);
                    const text_node = try doc.createNode(.text, display, .{ .text = doc.text(display) });
                    try doc.appendChild(link, text_node);
                    i += 1;
                },
                .footnote => |f| {
                    const node = try doc.createNode(.footnote_ref, subSpan(content, f.span.start, f.span.end), .{ .footnote_ref = f.number });
                    try doc.appendChild(scope.parent, node);
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

/// Parses one line's content into inline nodes under `parent`. `defs` is
/// the document's `[alias]url` table, resolved by link scanning.
fn parseInlines(doc: *document.Document, parent: *document.Node, content: source.Span, defs: *const AliasTable) ParseError!void {
    if (content.isEmpty()) return;
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    try scanLineItems(doc, &items, content, defs);
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
    try std.testing.expectEqual(@as(u8, 1), root.children.items[0].data.heading.level);
    try std.testing.expectEqualStrings("One", root.children.items[0].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    try std.testing.expectEqualStrings("Two", root.children.items[1].children.items[0].data.text);
    try std.testing.expectEqual(document.Tag.heading, root.children.items[2].tag);
    try std.testing.expectEqual(@as(u8, 6), root.children.items[2].data.heading.level);
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
    try std.testing.expectEqual(@as(u8, 2), heading.data.heading.level);
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

test "textile: empty block-quote signatures and the citation form stay literal" {
    const oliver = @import("oliver.zig");
    // Empty single- and extended-period signatures (behavior unspecified by
    // the references) and the deferred `bq:` citation form stay literal;
    // `bq..` with content is now the implemented extended quote.
    const cases = [_][]const u8{
        "bq.",
        "bq. \t",
        "bq..",
        "bq.. \t",
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

test "textile: tables structure, spans, and rendering" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "| a | b |\n| 1 | 2 |\n", .textile, .{});
    defer result.deinit();

    const table = result.document.root.children.items[0];
    try std.testing.expectEqual(document.Tag.table, table.tag);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 19 }, table.span);
    try std.testing.expect(!table.data.table.sections);
    try std.testing.expectEqual(@as(usize, 2), table.data.table.alignment.len);
    try std.testing.expectEqual(@as(usize, 0), table.data.table.attrs.len);
    try std.testing.expectEqual(@as(usize, 2), table.children.items.len);

    const row0 = table.children.items[0];
    try std.testing.expectEqual(document.Tag.table_row, row0.tag);
    try std.testing.expectEqual(source.Span{ .start = 0, .end = 9 }, row0.span);
    // Cell spans cover the verbatim content (` a `), pipes excluded.
    try std.testing.expectEqual(source.Span{ .start = 1, .end = 4 }, row0.children.items[0].span);
    try std.testing.expectEqual(source.Span{ .start = 5, .end = 8 }, row0.children.items[1].span);
    try std.testing.expect(!row0.children.items[0].data.table_cell.header);
    try std.testing.expectEqualStrings(" a ", row0.children.items[0].children.items[0].data.text);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    // Hobix: flat rows, no thead/tbody, cell whitespace preserved.
    try std.testing.expectEqualStrings(
        "<table>\n<tr>\n<td> a </td>\n<td> b </td>\n</tr>\n<tr>\n<td> 1 </td>\n<td> 2 </td>\n</tr>\n</table>\n",
        out.items,
    );
}

test "textile: cell modifiers compose attributes and spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "|_. a |<. b |\\2. c |/2. d |\n", .textile, .{});
    defer result.deinit();

    const table = result.document.root.children.items[0];
    const row = table.children.items[0];
    try std.testing.expectEqual(@as(usize, 4), row.children.items.len);

    // `_` header cell: <th>, no attributes.
    const c0 = row.children.items[0];
    try std.testing.expect(c0.data.table_cell.header);
    try std.testing.expectEqual(@as(usize, 0), c0.data.table_cell.attrs.len);
    try std.testing.expectEqualStrings("a ", c0.children.items[0].data.text);

    // `<.` alignment composes a text-align style (not the GFM align attr).
    const c1 = row.children.items[1];
    try std.testing.expect(!c1.data.table_cell.header);
    try std.testing.expectEqual(@as(usize, 1), c1.data.table_cell.attrs.len);
    try std.testing.expectEqualStrings("style", c1.data.table_cell.attrs[0].name);
    try std.testing.expectEqualStrings("text-align:left;", c1.data.table_cell.attrs[0].value);
    try std.testing.expectEqual(document.TableAlign.none, c1.data.table_cell.alignment);

    // `\\2.` colspan.
    const c2 = row.children.items[2];
    try std.testing.expectEqual(@as(u8, 2), c2.data.table_cell.colspan);
    try std.testing.expectEqual(@as(u8, 1), c2.data.table_cell.rowspan);

    // `/2.` rowspan.
    const c3 = row.children.items[3];
    try std.testing.expectEqual(@as(u8, 1), c3.data.table_cell.colspan);
    try std.testing.expectEqual(@as(u8, 2), c3.data.table_cell.rowspan);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<table>\n<tr>\n<th>a </th>\n<td style=\"text-align:left;\">b </td>\n<td colspan=\"2\">c </td>\n<td rowspan=\"2\">d </td>\n</tr>\n</table>\n",
        out.items,
    );
}

test "textile: header alignment propagates and row headers mark cells" {
    const oliver = @import("oliver.zig");
    // Textile 2: a header cell's alignment becomes the default for the
    // cells below it in the same column; the model's table.alignment
    // records the propagated column defaults.
    var result = try oliver.parse(std.testing.allocator, "|_<. a |_>. b |\n| c | d |\n", .textile, .{});
    defer result.deinit();

    const table = result.document.root.children.items[0];
    try std.testing.expectEqual(document.TableAlign.left, table.data.table.alignment[0]);
    try std.testing.expectEqual(document.TableAlign.right, table.data.table.alignment[1]);
    const header = table.children.items[0];
    try std.testing.expectEqualStrings("text-align:left;", header.children.items[0].data.table_cell.attrs[0].value);
    try std.testing.expectEqualStrings("text-align:right;", header.children.items[1].data.table_cell.attrs[0].value);
    const body = table.children.items[1];
    try std.testing.expectEqualStrings("text-align:left;", body.children.items[0].data.table_cell.attrs[0].value);
    try std.testing.expectEqualStrings("text-align:right;", body.children.items[1].data.table_cell.attrs[0].value);

    // A row-level `_` marks every cell of the row as a header cell.
    var result2 = try oliver.parse(std.testing.allocator, "_| a | b |\n", .textile, .{});
    defer result2.deinit();
    const row = result2.document.root.children.items[0].children.items[0];
    try std.testing.expect(row.children.items[0].data.table_cell.header);
    try std.testing.expect(row.children.items[1].data.table_cell.header);
}

test "textile: table signature and row modifiers" {
    const oliver = @import("oliver.zig");
    // The Textile 2 complex example: signature + first row on one line,
    // pipe-terminated row modifiers, a rowspan, and a header cell with a
    // cell style.
    var result = try oliver.parse(
        std.testing.allocator,
        "table(fig). {color:red}_|Top|Row|\n{color:blue}|/2. Second|Row|\n|_{color:green}. Last|\n",
        .textile,
        .{},
    );
    defer result.deinit();

    const table = result.document.root.children.items[0];
    try std.testing.expectEqual(document.Tag.table, table.tag);
    try std.testing.expectEqual(@as(usize, 1), table.data.table.attrs.len);
    try std.testing.expectEqualStrings("class", table.data.table.attrs[0].name);
    try std.testing.expectEqualStrings("fig", table.data.table.attrs[0].value);
    try std.testing.expect(!table.data.table.sections);

    const row0 = table.children.items[0];
    try std.testing.expectEqualStrings("color:red;", row0.data.table_row.attrs[0].value);
    try std.testing.expect(row0.children.items[0].data.table_cell.header);
    try std.testing.expect(row0.children.items[1].data.table_cell.header);
    try std.testing.expectEqualStrings("Top", row0.children.items[0].children.items[0].data.text);

    const row1 = table.children.items[1];
    try std.testing.expectEqualStrings("color:blue;", row1.data.table_row.attrs[0].value);
    try std.testing.expectEqual(@as(u8, 2), row1.children.items[0].data.table_cell.rowspan);

    // `|_{color:green}. Last|`: cell modifiers `_` + `{color:green}`.
    const row2 = table.children.items[2];
    try std.testing.expect(row2.children.items[0].data.table_cell.header);
    try std.testing.expectEqualStrings("color:green;", row2.children.items[0].data.table_cell.attrs[0].value);
    try std.testing.expectEqualStrings("Last", row2.children.items[0].children.items[0].data.text);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<table class=\"fig\">\n<tr style=\"color:red;\">\n<th>Top</th>\n<th>Row</th>\n</tr>\n<tr style=\"color:blue;\">\n<td rowspan=\"2\">Second</td>\n<td>Row</td>\n</tr>\n<tr>\n<th style=\"color:green;\">Last</th>\n</tr>\n</table>\n",
        out.items,
    );
}

test "textile: table fallbacks stay literal" {
    const oliver = @import("oliver.zig");

    // A row must end with `|`: `|a|b` is a paragraph.
    {
        var result = try oliver.parse(std.testing.allocator, "|a|b\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // Modifiers must be terminated by `. ` (the documented contract): the
    // `_` in `|_.< a |` cannot terminate mid-run, so the cell is verbatim.
    {
        var result = try oliver.parse(std.testing.allocator, "|_.< a |\n", .textile, .{});
        defer result.deinit();
        const cell = result.document.root.children.items[0].children.items[0].children.items[0];
        try std.testing.expect(!cell.data.table_cell.header);
        try std.testing.expectEqualStrings("_.< a ", cell.children.items[0].data.text);
    }
    // `table.` followed by non-row text is not a signature.
    {
        var result = try oliver.parse(std.testing.allocator, "table. of contents\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // A modifier run without a `. ` or `|` terminator is not a row.
    {
        var result = try oliver.parse(std.testing.allocator, "{a} b\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // A `table.` signature that never receives a row produces no table.
    {
        var result = try oliver.parse(std.testing.allocator, "table.\n\npara\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
        try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // An unclosed modifier brace keeps the whole cell literal, but the
    // line is still a row (it starts and ends with `|`).
    {
        var result = try oliver.parse(std.testing.allocator, "|{oops x|\n", .textile, .{});
        defer result.deinit();
        const table = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.table, table.tag);
        const cell = table.children.items[0].children.items[0];
        try std.testing.expectEqualStrings("{oops x", cell.children.items[0].data.text);
    }
}

test "textile: tables close on blank lines and other blocks" {
    const oliver = @import("oliver.zig");

    // A blank line separates two tables.
    {
        var result = try oliver.parse(std.testing.allocator, "|a|\n\n|b|\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.document.root.children.items.len);
        try std.testing.expectEqual(document.Tag.table, result.document.root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.table, result.document.root.children.items[1].tag);
    }
    // A plain line closes the table and starts a paragraph.
    {
        var result = try oliver.parse(std.testing.allocator, "|a|b|\nplain\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        try std.testing.expectEqual(document.Tag.table, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    // A heading closes the table.
    {
        var result = try oliver.parse(std.testing.allocator, "|a|b|\nh2. T\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(document.Tag.table, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.heading, root.children.items[1].tag);
    }
    // A new `table.` signature closes the open table.
    {
        var result = try oliver.parse(std.testing.allocator, "|a|b|\ntable.\n|c|\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        try std.testing.expectEqual(@as(usize, 1), root.children.items[0].children.items.len);
        try std.testing.expectEqual(@as(usize, 1), root.children.items[1].children.items.len);
    }
}

test "textile: table row storm stays linear and deterministic" {
    const oliver = @import("oliver.zig");
    const count = 20_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    for (0..count) |_| try input.appendSlice(std.testing.allocator, "| a | b |\n");

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    const table = result.document.root.children.items[0];
    try std.testing.expectEqual(@as(usize, count), table.children.items.len);

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

test "textile: tables converge with the markdown GFM model" {
    const oliver = @import("oliver.zig");

    // Both dialects produce the same table/row/cell node structure with
    // the same header flags. Documented differences (docs/TEXTILE-PARITY.md
    // §7): GFM renders `<thead>`/`<tbody>` sections and `align` attributes
    // and trims cell whitespace, while Textile renders flat rows with
    // `style` attributes and preserves cell whitespace verbatim — so the
    // convergence claim here is structural, not byte-identical.
    var md = try oliver.parse(std.testing.allocator, "| a | b |\n| --- | --- |\n| 1 | 2 |\n", .markdown, .{});
    defer md.deinit();
    var tx = try oliver.parse(std.testing.allocator, "|_. a |_. b |\n| 1 | 2 |\n", .textile, .{});
    defer tx.deinit();

    const md_table = md.document.root.children.items[0];
    const tx_table = tx.document.root.children.items[0];
    try std.testing.expectEqual(document.Tag.table, md_table.tag);
    try std.testing.expectEqual(document.Tag.table, tx_table.tag);
    try std.testing.expect(md_table.data.table.sections);
    try std.testing.expect(!tx_table.data.table.sections);
    try std.testing.expectEqual(md_table.children.items.len, tx_table.children.items.len);
    for (md_table.children.items, 0..) |md_row, ri| {
        const tx_row = tx_table.children.items[ri];
        try std.testing.expectEqual(md_row.children.items.len, tx_row.children.items.len);
        for (md_row.children.items, 0..) |md_cell, ci| {
            const tx_cell = tx_row.children.items[ci];
            try std.testing.expectEqual(md_cell.data.table_cell.header, tx_cell.data.table_cell.header);
            try std.testing.expectEqual(md_cell.data.table_cell.colspan, tx_cell.data.table_cell.colspan);
            try std.testing.expectEqual(md_cell.data.table_cell.rowspan, tx_cell.data.table_cell.rowspan);
        }
    }
}

test "textile: link aliases resolve through document definitions" {
    const oliver = @import("oliver.zig");
    // The Hobix "Link Aliases" example: the definition follows the uses.
    var result = try oliver.parse(
        std.testing.allocator,
        "I am crazy about \"Hobix\":hobix\nand \"it's\":hobix \"all\":hobix I ever\n\"link to\":hobix!\n[hobix]https://hobix.com\n",
        .textile,
        .{},
    );
    defer result.deinit();

    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    const p = root.children.items[0];
    var link_count: usize = 0;
    for (p.children.items) |child| {
        if (child.tag != .link) continue;
        link_count += 1;
        try std.testing.expectEqualStrings("https://hobix.com", child.data.link.href);
        try std.testing.expectEqual(document.Tag.text, child.children.items[0].tag);
    }
    try std.testing.expectEqual(@as(usize, 4), link_count);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    // The definition line never renders; the paragraph keeps its hard
    // breaks; the `!` after `hobix` is excluded trailing punctuation.
    try std.testing.expectEqualStrings(
        "<p>I am crazy about <a href=\"https://hobix.com\">Hobix</a><br />\nand <a href=\"https://hobix.com\">it's</a> <a href=\"https://hobix.com\">all</a> I ever<br />\n<a href=\"https://hobix.com\">link to</a>!</p>\n",
        out.items,
    );
}

test "textile: link alias shapes, precedence, and literal fallbacks" {
    const oliver = @import("oliver.zig");

    // First definition wins.
    {
        var result = try oliver.parse(std.testing.allocator, "[a]http://one\n[a]http://two\n\n\"x\":a\n", .textile, .{});
        defer result.deinit();
        const link = result.document.root.children.items[0].children.items[0];
        try std.testing.expectEqualStrings("http://one", link.data.link.href);
    }
    // Matching is case-sensitive: an undefined alias stays a relative URL.
    {
        var result = try oliver.parse(std.testing.allocator, "[a]http://u\n\n\"x\":A\n", .textile, .{});
        defer result.deinit();
        const link = result.document.root.children.items[0].children.items[0];
        try std.testing.expectEqualStrings("A", link.data.link.href);
    }
    // An undefined alias is an ordinary relative URL, not an error.
    {
        var result = try oliver.parse(std.testing.allocator, "\"x\":foo\n", .textile, .{});
        defer result.deinit();
        const link = result.document.root.children.items[0].children.items[0];
        try std.testing.expectEqualStrings("foo", link.data.link.href);
    }
    // A definition line vanishes mid-paragraph without splitting it.
    {
        var result = try oliver.parse(std.testing.allocator, "line one\n[a]http://u\nline two\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, p.tag);
        try std.testing.expectEqual(@as(usize, 3), p.children.items.len); // text + hard_break + text
    }
    // A bare definition block renders nothing.
    {
        var result = try oliver.parse(std.testing.allocator, "para\n\n[a]http://u\n\n[b]http://v\n\npara2\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.document.root.children.items.len);
    }
    // Non-definition shapes stay ordinary text (no links anywhere). `[x]`
    // is used rather than `[1]`, which is now a footnote reference (T13).
    {
        var result = try oliver.parse(std.testing.allocator, "[x] See note\n[]http://x\n[x]\n[x] url with space\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, p.tag);
        var it = try document.Document.Iterator.init(std.testing.allocator, result.document.root);
        defer it.deinit();
        var text_found = false;
        while (try it.next()) |n| {
            if (n.tag == .link) return error.unexpected_link;
            if (n.tag == .text and std.mem.indexOf(u8, n.data.text, "[x]") != null) text_found = true;
        }
        try std.testing.expect(text_found);
    }
}

test "textile: link aliases resolve in every inline context" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        std.testing.allocator,
        "h2. \"T\":a\n\n* \"one\":a\n* \"two\":a\n\n| \"cell\":a |\n\n[a]http://u\n",
        .textile,
        .{},
    );
    defer result.deinit();
    var it = try document.Document.Iterator.init(std.testing.allocator, result.document.root);
    defer it.deinit();
    var link_count: usize = 0;
    while (try it.next()) |n| {
        if (n.tag == .link) {
            link_count += 1;
            try std.testing.expectEqualStrings("http://u", n.data.link.href);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), link_count);
}

test "textile: link alias storm stays linear and deterministic" {
    const oliver = @import("oliver.zig");
    const count = 2_000;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    var buf: [48]u8 = undefined;
    for (0..count) |i| {
        const line = try std.fmt.bufPrint(&buf, "[a{d}]http://u{d}\n", .{ i, i });
        try input.appendSlice(std.testing.allocator, line);
    }
    for (0..count) |i| {
        const line = try std.fmt.bufPrint(&buf, "\"x\":a{d} ", .{i});
        try input.appendSlice(std.testing.allocator, line);
    }
    try input.append(std.testing.allocator, '\n');

    var result = try oliver.parse(std.testing.allocator, input.items, .textile, .{});
    defer result.deinit();
    var link_count: usize = 0;
    var it = try document.Document.Iterator.init(std.testing.allocator, result.document.root);
    defer it.deinit();
    while (try it.next()) |n| {
        if (n.tag == .link) link_count += 1;
    }
    try std.testing.expectEqual(@as(usize, count), link_count);

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

test "textile: block attributes on paragraph signatures" {
    const oliver = @import("oliver.zig");

    // Class, id, combined class#id, style, and lang (Hobix §4 examples).
    {
        var result = try oliver.parse(std.testing.allocator, "p(example1). An example\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, p.tag);
        try std.testing.expectEqual(@as(usize, 1), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("class", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("example1", p.data.paragraph.attrs[0].value);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "p(#big-red). Red here\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("id", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("big-red", p.data.paragraph.attrs[0].value);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "p(example1#big-red2). Red here\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 2), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("class", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("example1", p.data.paragraph.attrs[0].value);
        try std.testing.expectEqualStrings("id", p.data.paragraph.attrs[1].name);
        try std.testing.expectEqualStrings("big-red2", p.data.paragraph.attrs[1].value);
    }
    // Multi-declaration user styles are normalized: `;` grows a trailing
    // space, matching Hobix's `style="color:blue; margin:30px;"`.
    {
        var result = try oliver.parse(std.testing.allocator, "p{color:blue;margin:30px}. Spacey blue\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("style", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("color:blue; margin:30px;", p.data.paragraph.attrs[0].value);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "p[fr]. rouge\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("lang", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("fr", p.data.paragraph.attrs[0].value);
    }
}

test "textile: block alignment, indentation, and heading combinations" {
    const oliver = @import("oliver.zig");

    // `p<.`/`p>.`/`p=.`/`p<>.` set text-align; `p(.`/`p((.`/`p))).` set
    // padding (Hobix §4: a bare `(` needs no closing paren).
    const align_input = "p<. left\n\np>. right\n\np=. center\n\np<>. justify\n\np(. one\n\np((. two\n\np))). three\n";
    var result = try oliver.parse(std.testing.allocator, align_input, .textile, .{});
    defer result.deinit();
    const expect_styles = [_][]const u8{
        "text-align:left;",
        "text-align:right;",
        "text-align:center;",
        "text-align:justify;",
        "padding-left:1em;",
        "padding-left:2em;",
        "padding-right:3em;",
    };
    try std.testing.expectEqual(@as(usize, expect_styles.len), result.document.root.children.items.len);
    for (result.document.root.children.items, 0..) |node, i| {
        try std.testing.expectEqual(document.Tag.paragraph, node.tag);
        try std.testing.expectEqual(@as(usize, 1), node.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("style", node.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings(expect_styles[i], node.data.paragraph.attrs[0].value);
    }

    // The combined heading examples from Hobix.
    {
        var result2 = try oliver.parse(std.testing.allocator, "h2()>. Bingo.\n", .textile, .{});
        defer result2.deinit();
        const h = result2.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.heading, h.tag);
        try std.testing.expectEqual(@as(u8, 2), h.data.heading.level);
        try std.testing.expectEqual(@as(usize, 1), h.data.heading.attrs.len);
        try std.testing.expectEqualStrings("padding-left:1em; padding-right:1em; text-align:right;", h.data.heading.attrs[0].value);
    }
    {
        var result2 = try oliver.parse(std.testing.allocator, "h3()>[no]{color:red}. Bingo\n", .textile, .{});
        defer result2.deinit();
        const h = result2.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 2), h.data.heading.attrs.len);
        try std.testing.expectEqualStrings("style", h.data.heading.attrs[0].name);
        try std.testing.expectEqualStrings("color:red; padding-left:1em; padding-right:1em; text-align:right;", h.data.heading.attrs[0].value);
        try std.testing.expectEqualStrings("lang", h.data.heading.attrs[1].name);
        try std.testing.expectEqualStrings("no", h.data.heading.attrs[1].value);
    }
}

test "textile: blockquote attributes land on the quote, not the inner paragraph" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(std.testing.allocator, "bq{color:red}. A red quote\n\nbq>. right aligned\n", .textile, .{});
    defer result.deinit();
    const root = result.document.root;
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    for (root.children.items) |quote| {
        try std.testing.expectEqual(document.Tag.block_quote, quote.tag);
        try std.testing.expectEqual(@as(usize, 1), quote.data.block_quote.attrs.len);
        // The inner paragraph is unmarked.
        const inner = quote.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, inner.tag);
        try std.testing.expectEqual(@as(usize, 0), inner.data.paragraph.attrs.len);
    }
}

test "textile: malformed block signatures stay literal" {
    const oliver = @import("oliver.zig");
    // Unterminated class, missing space after the period, doubled periods,
    // the deferred citation form, and a non-`hN` heading marker are
    // ordinary text. (`bq..` with content is the implemented extended
    // quote, covered by the extended-block tests.)
    var result = try oliver.parse(
        std.testing.allocator,
        "p(foo not closed\n\np>.no-space\n\np.. double\n\nbq: citation\n\nh1x. not a heading\n",
        .textile,
        .{},
    );
    defer result.deinit();
    for (result.document.root.children.items) |node| {
        try std.testing.expectEqual(document.Tag.paragraph, node.tag);
        try std.testing.expectEqual(@as(usize, 0), node.data.paragraph.attrs.len);
    }
}

test "textile: bc. and pre. code-block structure and content" {
    const oliver = @import("oliver.zig");

    // `bc.` is an escaped `<pre><code>` block (Textile 2: "< and > are
    // translated into HTML entities automatically").
    {
        var result = try oliver.parse(std.testing.allocator, "bc. a < b\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
        const code = root.children.items[0];
        try std.testing.expectEqual(document.Tag.code_block, code.tag);
        try std.testing.expect(code.data.code_block.escape);
        try std.testing.expectEqualStrings("a < b\n", code.data.code_block.content);
    }
    // `pre.` is a verbatim `<pre>` block: no escaping, no `<code>` wrapper.
    {
        var result = try oliver.parse(std.testing.allocator, "pre. <b>x</b>\n", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.code_block, code.tag);
        try std.testing.expect(!code.data.code_block.escape);
        try std.testing.expectEqualStrings("<b>x</b>\n", code.data.code_block.content);
    }
    // Multi-line blocks collect every non-blank line verbatim, including
    // signature-shaped lines, until a blank line or EOF.
    {
        var result = try oliver.parse(std.testing.allocator, "bc. one\np. still code\n  three\n\np. after\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        const code = root.children.items[0];
        try std.testing.expectEqualStrings("one\np. still code\n  three\n", code.data.code_block.content);
        // The node span covers the whole block (first content start through
        // the last content line's end).
        try std.testing.expectEqual(@as(u32, 4), code.span.start);
        const after = root.children.items[1];
        try std.testing.expectEqual(document.Tag.paragraph, after.tag);
    }
    // EOF closes an unterminated block.
    {
        var result = try oliver.parse(std.testing.allocator, "pre. alpha\nbeta", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expectEqualStrings("alpha\nbeta\n", code.data.code_block.content);
    }
    // Modifiers land on the code block's attrs (rendered on `<pre>`).
    {
        var result = try oliver.parse(std.testing.allocator, "bc{color:red}. x\n", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), code.data.code_block.attrs.len);
        try std.testing.expectEqualStrings("style", code.data.code_block.attrs[0].name);
        try std.testing.expectEqualStrings("color:red;", code.data.code_block.attrs[0].value);
    }
}

test "textile: bc./pre. marker edge cases and block interaction" {
    const oliver = @import("oliver.zig");

    // Empty signatures, near misses, and plain words stay literal
    // paragraphs.
    var result = try oliver.parse(
        std.testing.allocator,
        "bc. \n\npre.\n\nbcd. not code\n\nbc\n\nprelude. not pre\n",
        .textile,
        .{},
    );
    defer result.deinit();
    for (result.document.root.children.items) |node| {
        try std.testing.expectEqual(document.Tag.paragraph, node.tag);
    }

    // A code block interrupts an open paragraph and closes lists/tables.
    {
        var result2 = try oliver.parse(std.testing.allocator, "para one\nbc. x\n", .textile, .{});
        defer result2.deinit();
        const root = result2.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.code_block, root.children.items[1].tag);
    }
}

test "textile: bq.. extended quote structure and termination" {
    const oliver = @import("oliver.zig");

    // The Textile 2 example: unmarked lines stay in the quote, a `p.`
    // signature ends it.
    {
        var result = try oliver.parse(
            std.testing.allocator,
            "bq.. This is paragraph one of a block quote.\nThis is paragraph two of a block quote.\np. Now we are back to a regular paragraph.\n",
            .textile,
            .{},
        );
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        const quote = root.children.items[0];
        try std.testing.expectEqual(document.Tag.block_quote, quote.tag);
        try std.testing.expectEqual(@as(usize, 1), quote.children.items.len);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    // Blank lines separate paragraphs inside the one blockquote; the inner
    // paragraphs are unmarked and the quote carries the signature's attrs.
    {
        var result = try oliver.parse(std.testing.allocator, "bq{color:red}.. first\n\nsecond\n\np. done\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        const quote = root.children.items[0];
        try std.testing.expectEqual(@as(usize, 1), quote.data.block_quote.attrs.len);
        try std.testing.expectEqualStrings("color:red;", quote.data.block_quote.attrs[0].value);
        try std.testing.expectEqual(@as(usize, 2), quote.children.items.len);
        for (quote.children.items) |para| {
            try std.testing.expectEqual(document.Tag.paragraph, para.tag);
            try std.testing.expectEqual(@as(usize, 0), para.data.paragraph.attrs.len);
        }
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    // A heading and another quote signature also terminate; an empty `bq..`
    // stays literal; EOF closes cleanly.
    {
        var result = try oliver.parse(std.testing.allocator, "bq.. quote\n\nh2. Head\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.heading, root.children.items[1].tag);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "bq.. last line", .textile, .{});
        defer result.deinit();
        const quote = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.block_quote, quote.tag);
        try std.testing.expectEqual(@as(usize, 1), quote.children.items.len);
    }
}

test "textile: bc.. and pre.. extended code keep blank lines" {
    const oliver = @import("oliver.zig");

    // Blank lines are verbatim content; the block ends at the next block
    // signature or EOF.
    {
        var result = try oliver.parse(std.testing.allocator, "bc.. line one\n\nline three\np. after\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        const code = root.children.items[0];
        try std.testing.expectEqual(document.Tag.code_block, code.tag);
        try std.testing.expectEqualStrings("line one\n\nline three\n", code.data.code_block.content);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "pre.. <b>x</b>\n\n& y", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expect(!code.data.code_block.escape);
        try std.testing.expectEqualStrings("<b>x</b>\n\n& y\n", code.data.code_block.content);
    }
    // A table row stays code content; list markers and plain lines too.
    {
        var result = try oliver.parse(std.testing.allocator, "bc.. a\n|x|y|\n* not a list\n\np. after\n", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expectEqualStrings("a\n|x|y|\n* not a list\n\n", code.data.code_block.content);
    }
}

test "textile: extended-block ownership and literal fallbacks" {
    const oliver = @import("oliver.zig");

    // A def line inside an extended quote vanishes; inside extended code it
    // is verbatim content.
    {
        var result = try oliver.parse(std.testing.allocator, "bq.. quote\n[a]http://u\nmore\n\np. after\n", .textile, .{});
        defer result.deinit();
        const quote = result.document.root.children.items[0];
        const para = quote.children.items[0];
        try std.testing.expectEqual(@as(usize, 3), para.children.items.len); // text + break + text
        try std.testing.expectEqualStrings("quote", para.children.items[0].data.text);
        try std.testing.expectEqualStrings("more", para.children.items[2].data.text);
    }
    {
        var result = try oliver.parse(std.testing.allocator, "bc.. a\n[x]http://u\nb\n", .textile, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try std.testing.expectEqualStrings("a\n[x]http://u\nb\n", code.data.code_block.content);
    }
    // Empty extended signatures and near misses stay literal; `p..` and
    // `h1..` are not extended signatures.
    var result = try oliver.parse(
        std.testing.allocator,
        "bq..\n\nbc.. \n\np.. not extended\n\nh1.. not extended\n\nbq. single still works\n",
        .textile,
        .{},
    );
    defer result.deinit();
    const root = result.document.root;
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[2].tag);
    try std.testing.expectEqual(document.Tag.paragraph, root.children.items[3].tag);
    try std.testing.expectEqual(document.Tag.block_quote, root.children.items[4].tag);
}

test "textile: fnN. footnote block structure" {
    const oliver = @import("oliver.zig");

    // The Textile 2 rendered form: `<p class="footnote" id="fn1"><sup>1</sup>
    // content</p>` — the paragraph carries the class/id attrs, a leading
    // plain sup with the number, a separating space, then inline content.
    {
        var result = try oliver.parse(std.testing.allocator, "fn1. Down here, in fact.\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(document.Tag.paragraph, p.tag);
        try std.testing.expectEqual(@as(usize, 2), p.data.paragraph.attrs.len);
        try std.testing.expectEqualStrings("class", p.data.paragraph.attrs[0].name);
        try std.testing.expectEqualStrings("footnote", p.data.paragraph.attrs[0].value);
        try std.testing.expectEqualStrings("id", p.data.paragraph.attrs[1].name);
        try std.testing.expectEqualStrings("fn1", p.data.paragraph.attrs[1].value);
        try std.testing.expectEqual(@as(usize, 3), p.children.items.len); // sup + space + text
        const sup = p.children.items[0];
        try std.testing.expectEqual(document.Tag.superscript, sup.tag);
        try std.testing.expectEqualStrings("1", sup.children.items[0].data.text);
        try std.testing.expectEqualStrings(" ", p.children.items[1].data.text);
        try std.testing.expectEqualStrings("Down here, in fact.", p.children.items[2].data.text);
    }
    // A footnote block is a paragraph: continuation lines join with hard
    // breaks, a blank line or signature ends it.
    {
        var result = try oliver.parse(std.testing.allocator, "fn2. first\nsecond\n\np. after\n", .textile, .{});
        defer result.deinit();
        const root = result.document.root;
        try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
        const p = root.children.items[0];
        try std.testing.expectEqualStrings("fn2", p.data.paragraph.attrs[1].value);
        // sup, space, text, hard_break, text
        try std.testing.expectEqual(@as(usize, 5), p.children.items.len);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    // Multi-digit numbers.
    {
        var result = try oliver.parse(std.testing.allocator, "fn12. Twelfth.\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqualStrings("fn12", p.data.paragraph.attrs[1].value);
        try std.testing.expectEqualStrings("12", p.children.items[0].children.items[0].data.text);
    }
}

test "textile: [N] footnote references in every inline context" {
    const oliver = @import("oliver.zig");

    // A `[N]` marker becomes a footnote_ref leaf; no boundary is required
    // (Hobix: "elsewhere[1].").
    {
        var result = try oliver.parse(std.testing.allocator, "This is covered elsewhere[1].\n", .textile, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try std.testing.expectEqual(@as(usize, 3), p.children.items.len); // text + ref + text
        const ref = p.children.items[1];
        try std.testing.expectEqual(document.Tag.footnote_ref, ref.tag);
        try std.testing.expectEqual(@as(u16, 1), ref.data.footnote_ref);
    }
    // Refs resolve in headings, list items, and table cells (the shared
    // inline seam).
    {
        var result = try oliver.parse(
            std.testing.allocator,
            "h2. Head [3]\n\n* item[4]\n\n| cell[5] |\n\nfn3. Third.\n\nfn4. Fourth.\n\nfn5. Fifth.\n",
            .textile,
            .{},
        );
        defer result.deinit();
        var it = try document.Document.Iterator.init(std.testing.allocator, result.document.root);
        defer it.deinit();
        var ref_count: usize = 0;
        while (try it.next()) |n| {
            if (n.tag == .footnote_ref) ref_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), ref_count);
    }
    // Multi-digit refs carry the whole number.
    {
        var result = try oliver.parse(std.testing.allocator, "Note[12].\n", .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(u16, 12), result.document.root.children.items[0].children.items[1].data.footnote_ref);
    }
}

test "textile: footnote literal fallbacks and marker edges" {
    const oliver = @import("oliver.zig");

    // Bracketed shapes that are not `[digits]` stay text; `fn` markers
    // without a digit run, a period+space, or content stay literal.
    var result = try oliver.parse(
        std.testing.allocator,
        "[x] letter\n\n[ 1] space\n\nfn1 no period\n\nfnx. no digit\n\nfn1. \n\nfn1.. double\n",
        .textile,
        .{},
    );
    defer result.deinit();
    for (result.document.root.children.items) |node| {
        try std.testing.expectEqual(document.Tag.paragraph, node.tag);
        try std.testing.expectEqual(@as(usize, 0), node.data.paragraph.attrs.len);
    }

    // `[0]` is a digit run and resolves like any other (both references
    // accept "a number inside" without a lower bound).
    {
        var result2 = try oliver.parse(std.testing.allocator, "fn0. Zero.\n\nsee[0]\n", .textile, .{});
        defer result2.deinit();
        const root = result2.document.root;
        try std.testing.expectEqual(document.Tag.footnote_ref, root.children.items[1].children.items[1].tag);
        try std.testing.expectEqual(@as(u16, 0), root.children.items[1].children.items[1].data.footnote_ref);
    }

    // A `fnN.` signature terminates an open extended quote.
    {
        var result3 = try oliver.parse(std.testing.allocator, "bq.. quote\nfn1. ends it\n", .textile, .{});
        defer result3.deinit();
        const root = result3.document.root;
        try std.testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
        try std.testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
        try std.testing.expectEqualStrings("fn1", root.children.items[1].data.paragraph.attrs[1].value);
    }
}
