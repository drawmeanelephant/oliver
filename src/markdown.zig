//! Markdown frontend.
//!
//! Implemented: paragraphs, ATX and Setext headings (§4.2/§4.3), thematic
//! breaks (§4.1), fenced code blocks (§4.5), block quotes (§5.1), list items
//! and lists (§5.2/§5.3), backslash escapes, hard and soft line breaks,
//! emphasis and strong emphasis, code spans (§6.1), raw HTML tags (§6.6),
//! inline links (§6.3), inline images (§6.4), and autolinks (§6.5). Behavior
//! is taken from the CommonMark specification (0.31.2) where the slice
//! implements it; divergences and chosen behaviors are documented in
//! docs/FEATURE-MATRIX.md, and the emphasis/strong algorithm is derived
//! in docs/INLINE-PARSING.md (leaf blocks: docs/LEAF-BLOCKS.md and
//! docs/FENCED-CODE.md; images: docs/IMAGES-PARSING.md;
//! autolinks: docs/AUTOLINKS.md).
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
//! earlier `[` (links cannot contain links, §6.3), links are always
//! innermost-first and link text never contains another link. This is the
//! second delimiter-opacity rule (link brackets bind more tightly than
//! emphasis; `*[foo*](/uri)` is a link).
//!
//! Inline images ride the same discovery pass: `![` is its own opener on
//! the bracket stack, and an image description may contain links and
//! images — a formed link inactivates only earlier `[` openers, never
//! `![` (spec appendix; docs/IMAGES-PARSING.md §2). The description is
//! matched as a fresh inline scope and then flattened to the arena-owned
//! `alt` string (the spec's "only the plain string content of the image
//! description"), so `.image` is a leaf node like `code_span`. Images
//! reuse the link `(...)` parser and its DoS guards verbatim.
//!
//! Autolinks (§6.5) are recognized at scan time, like code spans: on an
//! unescaped `<` the scan tries a URI autolink (`<scheme:...>`, scheme
//! 2-32 chars) then an email autolink (`<user@host>`, the HTML5 regex),
//! and a match becomes a leaf `autolink` item whose content is opaque to
//! the delimiter stack and to link discovery (docs/AUTOLINKS.md §2). The
//! first-come-wins rule with code spans falls out of the left-to-right
//! walk: a backtick run before the `<` is skipped as a code span, a `<`
//! before the backticks consumes them as ordinary URI content.
//!
//! Raw HTML tags (§6.6) are discovered over the whole paragraph before the
//! line scan, because open/closing tags, comments, processing instructions,
//! declarations, and CDATA sections may span line endings. The discovered
//! tags merge with code spans into one first-come opaque-construct list;
//! recognized tags become leaf `raw_html` items whose source spans are
//! rendered verbatim (docs/RAW-HTML.md).
//!
//! The parser runs in two passes, matching the spec's precedence model:
//! block structure first, then inline structure. The block pass recognizes
//! paragraphs, ATX and Setext headings, thematic breaks, fenced code blocks,
//! block quotes, list items, and lists; unsupported leaf-block forms currently
//! fall back to paragraphs.
//!
//! The inline pass is discovery plus three phases (see
//! docs/INLINE-PARSING.md §8):
//!   scan  — one pass over each line's raw content span, producing a flat
//!           item list (text runs, delimiter runs, opaque constructs, line
//!           breaks). Flanking is computed against the raw span, so trailing
//!           whitespace and line boundaries classify runs exactly as the
//!           spec's "beginning and end of the line count as Unicode
//!           whitespace" requires; the leading/trailing whitespace trimming
//!           happens at emission.
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
//!   inline parsing (spec §4.2); a terminal backslash stays literal because
//!   hard breaks require a following inline-content line.

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");
const diagnostic = @import("diagnostic.zig");
const unicode = @import("unicode.zig");

pub const ParseError = error{OutOfMemory};

/// Parses `doc.src` as Markdown, appending block nodes under `doc.root`.
/// The caller (`oliver.parse`) guarantees
/// `doc.src.bytes.len <= source.max_input_len`, so all offsets fit in `u32`.
pub fn parse(doc: *document.Document, diags: *std.ArrayList(diagnostic.Diagnostic)) ParseError!void {
    _ = diags;

    // Two-phase parse (spec appendix "A parsing strategy"): phase 1 builds
    // the block structure and collects link reference definitions (§4.7)
    // into `defs`; inline parsing is deferred to phase 2, because a
    // reference link may precede the definition it uses. `pending` records
    // each block's raw content for the second pass.
    //
    // Phase 1 keeps a stack of open *container* blocks (block quotes, lists,
    // list items) plus one open leaf (a paragraph). Each line is matched
    // against the containers top-down, consuming markers and indentation;
    // unmatched containers stay open only for a lazy paragraph continuation,
    // and are otherwise closed (see docs/BLOCKS-PARSING.md §5). The document
    // root is implicit below the stack, so `leafParent` is the deepest
    // container or `doc.root`.
    var defs = Definitions.init(doc.allocator());
    defer defs.deinit();
    var pending = std.ArrayList(PendingInline).empty;
    defer pending.deinit(doc.allocator());
    var containers = std.ArrayList(ContainerState).empty;
    defer containers.deinit(doc.allocator());
    var paragraph: ?Paragraph = null;
    var fenced: ?FencedCode = null;

    var lines = source.Lines.init(doc.src.bytes);
    while (lines.next()) |line| {
        // A. Match open containers top-down, consuming one marker each. A
        // block quote consumes `> `; a list item consumes its content
        // indentation; a list consumes nothing (its fate is decided by its
        // item and by whether a new same-type item starts).
        var view = line;
        var matched: usize = 0;
        while (matched < containers.items.len) {
            const c = &containers.items[matched];
            switch (c.node.tag) {
                .block_quote => {
                    const stripped = tryStripBlockQuoteMarker(view) orelse break;
                    view = stripped;
                },
                .list => {
                    // With no item on the stack below it the list is dead
                    // (its blank-start item was already popped).
                    if (matched + 1 >= containers.items.len) break;
                },
                .list_item => {
                    if (c.inert) break;
                    if (isBlank(view.text)) {
                        // Blank lines match list items without requiring the
                        // full content indentation. Still consume as much of
                        // that structural indentation as is present: an open
                        // fenced leaf observes excess spaces as literal code,
                        // but never the list item's own prefix.
                        if (c.initial_blank_pending) c.inert = true;
                        view = advance(view, @min(countIndent(view.text), c.content_indent));
                    } else {
                        const indent = countIndent(view.text);
                        if (indent < c.content_indent) break;
                        view = advance(view, c.content_indent);
                        // Rule 3 limits only the blank prefix before the
                        // item's first block. Once nonblank content matches,
                        // later blank lines are ordinary item content.
                        c.initial_blank_pending = false;
                    }
                },
                else => unreachable,
            }
            matched += 1;
        }

        // An open fenced-code leaf owns every line while its containing
        // containers still match. Its contents are literal: no blank-line,
        // lazy-continuation, block-start, or inline rule runs here. If a
        // containing block ends, finalize without backtracking and reprocess
        // this same physical line normally outside the container.
        if (fenced) |*active| {
            if (matched == active.container_depth) {
                if (isFenceClose(view, active.marker, active.fence_len)) {
                    active.node.span.end = @intCast(view.content_end);
                    finishFencedCode(&fenced);
                    extendContainerSpans(&containers, view);
                    continue;
                }
                try appendFencedContentLine(doc, active, view);
                active.node.span.end = @intCast(view.content_end);
                extendContainerSpans(&containers, view);
                continue;
            }
            std.debug.assert(matched < active.container_depth);
            finishFencedCode(&fenced);
        }

        // The same physical line can be re-examined at many nested list
        // depths. Summarize its thematic-break suffixes once so precedence
        // checks stay O(1) per consumed container marker. Literal fenced-code
        // content bypasses this work above.
        const thematic_facts = ThematicLineFacts.init(line);

        // B. Blank line: close the leaf and any container whose marker was
        // absent. Blank lines keep block quotes (marker-blank) and list
        // items open; a blank line may make a list loose, but the decision
        // is deferred until the next line shows whether the blank separated
        // blocks inside an item or two items (§5.3).
        if (isBlank(view.text)) {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            noteListBlankLines(&containers, matched);
            containers.shrinkRetainingCapacity(matched);
            // A blank line with only a dead item on the stack (an inert
            // blank-start item failed to match) closes its list too.
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                containers.shrinkRetainingCapacity(containers.items.len - 1);
            }
            extendContainerSpans(&containers, view);
            continue;
        }

        // C. Lazy continuation (§5.1 rule 2, §5.2 rule 5): a line that
        // fails a container's condition can still continue the paragraph
        // inside it, if the remainder is paragraph continuation text.
        // Otherwise the unmatched containers close and the line is
        // reprocessed as a fresh start. A list whose item failed without a
        // replacement item closes too.
        if (matched < containers.items.len) {
            const list_sibling = startsListSibling(&containers, matched, view, &thematic_facts);
            resolveListBlankPending(&containers, matched, view, &thematic_facts);
            if (paragraph != null and !list_sibling and isParagraphContinuationText(view, &thematic_facts)) {
                try appendParagraphLine(doc, &paragraph, view);
                extendContainerSpans(&containers, view);
                continue;
            }
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            containers.shrinkRetainingCapacity(matched);
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                const top_list = containers.items[containers.items.len - 1].node;
                const m = tryListMarkerAfterLeafPrecedence(view, &thematic_facts);
                if (m == null or !sameListType(top_list, m.?)) {
                    containers.shrinkRetainingCapacity(containers.items.len - 1);
                }
            }
        } else {
            resolveListBlankPending(&containers, matched, view, &thematic_facts);
        }

        // D. New block starts on the remainder. Block quotes and list
        // markers may nest (each consumes its marker and the remainder is
        // re-examined). Thematic breaks take precedence over list markers;
        // a Setext underline transforms an eligible open paragraph before a
        // one- or two-dash line can become an empty list item (§4.1/§4.3).
        // A list item interrupts an open paragraph only when it can (§5.2
        // rule 1 exceptions); otherwise the line is paragraph text.
        while (true) {
            if (tryStripBlockQuoteMarker(view)) |stripped| {
                try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
                const node = try doc.createNode(.block_quote, stripped.contentSpan(), .none);
                try doc.appendChild(leafParent(doc, &containers), node);
                try containers.append(doc.allocator(), .{ .node = node });
                view = stripped;
                continue;
            }
            if (isThematicBreak(view, &thematic_facts) or
                (trySetextUnderline(view) != null and setextContentIndex(doc, paragraph) != null))
            {
                break;
            }
            if (tryListMarker(view)) |m| {
                if (paragraph != null and !m.can_interrupt) break;
                try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
                // Reuse an open same-type list, or close a different-type
                // list, or open a new list under the current parent.
                var list_node: *document.Node = undefined;
                if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                    const top_state = &containers.items[containers.items.len - 1];
                    const top = top_state.node;
                    if (sameListType(top, m)) {
                        list_node = top;
                    } else {
                        containers.shrinkRetainingCapacity(containers.items.len - 1);
                        list_node = try doc.createNode(.list, m.rest.contentSpan(), .{ .list = m.listData() });
                        try doc.appendChild(leafParent(doc, &containers), list_node);
                        try containers.append(doc.allocator(), .{ .node = list_node });
                    }
                } else {
                    list_node = try doc.createNode(.list, m.rest.contentSpan(), .{ .list = m.listData() });
                    try doc.appendChild(leafParent(doc, &containers), list_node);
                    try containers.append(doc.allocator(), .{ .node = list_node });
                }
                const item = try doc.createNode(.list_item, m.rest.contentSpan(), .none);
                try doc.appendChild(list_node, item);
                try containers.append(doc.allocator(), .{
                    .node = item,
                    .content_indent = m.content_indent,
                    .initial_blank_pending = m.blank_start,
                });
                view = m.rest;
                continue;
            }
            break;
        }
        // A marker-only line (`>` alone, or a line whose markers are all
        // consumed, or a blank-start list item) is a blank line inside the
        // container, not an empty paragraph.
        if (isBlank(view.text)) {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            extendContainerSpans(&containers, view);
            continue;
        }
        if (tryFenceOpen(view)) |opening| {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            const info = if (opening.info.isEmpty())
                null
            else
                try resolveEscapes(doc, opening.info);
            const node = try doc.createNode(.code_block, view.contentSpan(), .{
                .code_block = .{ .content = &.{}, .info = info },
            });
            try doc.appendChild(leafParent(doc, &containers), node);
            fenced = .{
                .node = node,
                .marker = opening.marker,
                .fence_len = opening.fence_len,
                .indent = opening.indent,
                .container_depth = containers.items.len,
            };
            extendContainerSpans(&containers, view);
            continue;
        }
        if (trySetextUnderline(view)) |underline| {
            if (try emitSetextHeading(
                doc,
                &paragraph,
                view,
                underline,
                leafParent(doc, &containers),
                &defs,
                &pending,
            )) {
                extendContainerSpans(&containers, view);
                continue;
            }
        }
        if (isThematicBreak(view, &thematic_facts)) {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            // A failed list item can leave its list as the deepest matched
            // container. A thematic break is not a sibling item: it belongs
            // beside that list, never directly under the `.list` node.
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                containers.shrinkRetainingCapacity(containers.items.len - 1);
            }
            const node = try doc.createNode(.thematic_break, view.contentSpan(), .none);
            try doc.appendChild(leafParent(doc, &containers), node);
            extendContainerSpans(&containers, view);
            continue;
        }
        if (tryAtxHeading(view)) |heading| {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);
            try emitHeading(doc, view, heading, leafParent(doc, &containers), &pending);
            extendContainerSpans(&containers, view);
            continue;
        }

        // E. Paragraph text.
        try appendParagraphLine(doc, &paragraph, view);
        extendContainerSpans(&containers, view);
    }
    finishFencedCode(&fenced);
    try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending);

    // Phase 2: inline pass, with the full definitions map available.
    for (pending.items) |job| {
        switch (job) {
            .paragraph => |pp| try parseParagraphInlines(doc, pp.node, pp.lines, &defs),
            .heading => |hh| try parseHeadingInlines(doc, hh.node, hh.span, &defs),
            .setext_heading => |hh| try parseSetextHeadingInlines(doc, hh.node, hh.lines, &defs),
        }
    }
}

/// Per-container state on the phase-1 stack.
const ContainerState = struct {
    node: *document.Node,
    /// For `.list_item`: the content indentation (marker indentation + W +
    /// N, §5.2 rules 1–3), in spaces — how far a continuation line must be
    /// indented to stay in the item.
    content_indent: u32 = 0,
    /// For `.list_item`: no nonblank block has followed a marker-only start
    /// yet. A second blank while this is true makes the item inert (§5.2
    /// rule 3); the flag clears when the first nonblank content line matches.
    initial_blank_pending: bool = false,
    /// For `.list_item`: dead after its second blank line ("A list item can
    /// begin with at most one blank line"); matches nothing.
    inert: bool = false,
    /// For `.list`: a blank line was seen while this list was open. The
    /// loose decision is deferred (docs/BLOCKS-PARSING.md §4) until the next
    /// line shows whether it separates direct blocks/items in this list.
    blank_pending: bool = false,
};

/// The node under which a new leaf or container is created: the deepest
/// open container, or the document root when the stack is empty.
fn leafParent(doc: *document.Document, containers: *const std.ArrayList(ContainerState)) *document.Node {
    if (containers.items.len == 0) return doc.root;
    return containers.items[containers.items.len - 1].node;
}

/// Extends every open container's span end to cover the current line, so a
/// block quote's or list item's span is the union of its (marker-stripped)
/// content lines. `line.content_end` is the full line's content end;
/// stripping only moves the start, so this is correct for matched, lazy,
/// and blank-marker lines alike.
fn extendContainerSpans(containers: *const std.ArrayList(ContainerState), line: source.Line) void {
    const end: u32 = @intCast(line.content_end);
    for (containers.items) |c| {
        if (c.node.span.end < end) c.node.span.end = end;
    }
}

/// Strips one block quote marker (§5.1): up to three leading spaces, `>`,
/// then one following space of indentation. Returns the stripped view or
/// null. A tab anywhere in the leading indentation disqualifies the marker
/// (full tab handling is deferred, see docs/BLOCKS-PARSING.md §7).
fn tryStripBlockQuoteMarker(line: source.Line) ?source.Line {
    const t = line.text;
    var i: usize = 0;
    var indent: usize = 0;
    while (i < t.len and t[i] == ' ' and indent < 3) : (i += 1) indent += 1;
    if (i >= t.len or t[i] != '>') return null;
    i += 1;
    if (i < t.len and t[i] == ' ') i += 1;
    return .{
        .text = t[i..],
        .start = line.start + i,
        .content_end = line.content_end,
        .end = line.end,
    };
}

/// A list marker recognized on a line (§5.2): a bullet character (`-`,
/// `+`, `*`) or 1–9 digits followed by `.` or `)`, optionally preceded by
/// up to three spaces.
const ListMarker = struct {
    const Kind = enum { bullet, ordered };

    kind: Kind,
    /// Bullet marker character, for same-type merging (§5.3).
    bullet: u8 = 0,
    /// Ordered delimiter (`.` or `)`), for same-type merging.
    delimiter: u8 = 0,
    /// Ordered start number (the marker's number; 1 for bullets).
    start: u32 = 1,
    /// Marker width W (1 for bullets; digits + 1 for ordered).
    width: u32,
    /// Content indentation of the item being opened: marker indentation
    /// plus W plus N (§5.2 rules 1–3; N=1 for blank-start and
    /// indented-code-first items).
    content_indent: u32,
    /// The item's first line begins with a blank line (rule 3).
    blank_start: bool,
    /// The line after the marker and its indentation.
    rest: source.Line,
    /// Whether the item may interrupt an open paragraph: not when it
    /// begins with a blank line, and for ordered items not when the start
    /// number is not 1 (§5.2 rule 1 exceptions).
    can_interrupt: bool,

    fn listData(self: ListMarker) document.List {
        return switch (self.kind) {
            .bullet => .{ .kind = .bullet, .bullet = self.bullet },
            .ordered => .{ .kind = .ordered, .delimiter = self.delimiter, .start = self.start },
        };
    }
};

/// Recognizes a list marker at the start of `line` (§5.2). The marker may
/// be preceded by up to three spaces (measured in the current view — a
/// quote's content — so nested lists compose); a tab disqualifies the line
/// (full tab handling deferred). The content indentation is the marker's
/// own indentation plus W plus N (rules 1–3): the spec's "let the width and
/// indentation of the list marker determine the indentation necessary for
/// blocks to fall under the list item" (docs/BLOCKS-PARSING.md §3).
fn tryListMarker(line: source.Line) ?ListMarker {
    const t = line.text;
    var i: usize = 0;
    var marker_indent: u32 = 0;
    while (i < t.len and t[i] == ' ' and marker_indent < 3) : (i += 1) marker_indent += 1;
    if (i >= t.len or t[i] == '\t') return null;

    var kind: ListMarker.Kind = undefined;
    var bullet: u8 = 0;
    var delimiter: u8 = 0;
    var start: u32 = 1;
    var width: u32 = 0;
    if (t[i] == '-' or t[i] == '+' or t[i] == '*') {
        kind = .bullet;
        bullet = t[i];
        width = 1;
        i += 1;
    } else if (t[i] >= '0' and t[i] <= '9') {
        const digit_start = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
        const digits = i - digit_start;
        if (digits > 9) return null; // §5.2: at most nine digits
        if (i >= t.len or (t[i] != '.' and t[i] != ')')) return null;
        kind = .ordered;
        delimiter = t[i];
        var n: u32 = 0;
        for (t[digit_start..i]) |b| n = n * 10 + (b - '0');
        start = n;
        width = @intCast(digits + 1);
        i += 1;
    } else {
        return null;
    }

    // Spaces after the marker (tabs deferred).
    const space_start = i;
    while (i < t.len and t[i] == ' ') : (i += 1) {}
    if (i < t.len and t[i] == '\t') return null;
    const n: u32 = @intCast(i - space_start);

    var blank_start = false;
    var content_indent: u32 = 0;
    var rest: source.Line = undefined;
    if (i >= t.len) {
        // Nothing after the marker: the item starts with a blank line
        // (rule 3); required indentation is W+1.
        blank_start = true;
        content_indent = marker_indent + width + 1;
        rest = .{ .text = t[i..], .start = line.start + i, .content_end = line.content_end, .end = line.end };
    } else if (n == 0) {
        return null; // the marker must be followed by 1–4 spaces
    } else if (n <= 4) {
        // Rule 1: the first block is ordinary content; indentation W+N.
        content_indent = marker_indent + width + n;
        rest = .{ .text = t[i..], .start = line.start + i, .content_end = line.content_end, .end = line.end };
    } else {
        // 5+ spaces: the first block is an indented code block (rule 2);
        // content indentation is W+1 and the code's own four spaces follow.
        content_indent = marker_indent + width + 1;
        const after_one = i - (n - 1);
        rest = .{ .text = t[after_one..], .start = line.start + after_one, .content_end = line.content_end, .end = line.end };
    }

    return .{
        .kind = kind,
        .bullet = bullet,
        .delimiter = delimiter,
        .start = start,
        .width = width,
        .content_indent = content_indent,
        .blank_start = blank_start,
        .rest = rest,
        .can_interrupt = !blank_start and (kind == .bullet or start == 1),
    };
}

/// Applies the §4.1 precedence rule before interpreting a line as a list
/// marker: a thematic break is never a list item, even when its first marker
/// and following whitespace also satisfy the list-marker grammar.
fn tryListMarkerAfterLeafPrecedence(
    line: source.Line,
    thematic_facts: *const ThematicLineFacts,
) ?ListMarker {
    if (isThematicBreak(line, thematic_facts)) return null;
    return tryListMarker(line);
}

/// Are `m`'s items of the same list type as `list_node` (§5.3): same
/// bullet character, or same ordered delimiter?
fn sameListType(list_node: *document.Node, m: ListMarker) bool {
    const list = list_node.data.list;
    return switch (m.kind) {
        .bullet => list.kind == .bullet and list.bullet == m.bullet,
        .ordered => list.kind == .ordered and list.delimiter == m.delimiter,
    };
}

/// Leading spaces of a line (tabs deferred: a tab stops the count).
fn countIndent(text: []const u8) u32 {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    return @intCast(i);
}

/// Advances a line view by `n` bytes (a matched container's consumed
/// indentation). `content_end`/`end` are absolute, so they are unchanged.
fn advance(line: source.Line, n: u32) source.Line {
    const k: usize = n;
    return .{
        .text = line.text[k..],
        .start = line.start + k,
        .content_end = line.content_end,
        .end = line.end,
    };
}

/// Records a blank line for each open list whose direct item is matched by
/// this line. A blank line in a nested list must not make an enclosing list
/// loose; a blank line with no intervening blockquote marker, however, can
/// separate an outer item's nested block from its next block, so all list
/// levels are recorded here and resolved when the next nonblank line shows
/// which level the blank belonged to.
fn noteListBlankLines(containers: *std.ArrayList(ContainerState), matched: usize) void {
    for (containers.items, 0..) |*state, i| {
        if (i >= matched or state.node.tag != .list) continue;
        if (i + 1 >= matched or containers.items[i + 1].node.tag != .list_item) continue;

        var inside_quote = false;
        var j = i + 2;
        while (j < matched) : (j += 1) {
            if (containers.items[j].node.tag == .block_quote) {
                inside_quote = true;
                break;
            }
        }
        if (!inside_quote) state.blank_pending = true;
    }
}

/// A marker at the point where an open list's direct item failed is a
/// sibling item, even when the marker would not be allowed to interrupt a
/// paragraph at the document level (for example `2.` or a blank item). The
/// active list makes the block boundary unambiguous.
fn startsListSibling(
    containers: *const std.ArrayList(ContainerState),
    matched: usize,
    line: source.Line,
    thematic_facts: *const ThematicLineFacts,
) bool {
    if (matched == 0 or matched > containers.items.len) return false;
    if (containers.items[matched - 1].node.tag != .list) return false;
    return tryListMarkerAfterLeafPrecedence(line, thematic_facts) != null;
}

/// Resolves pending blank lines once a nonblank line arrives. A list is loose
/// when the line resumes its direct item after the blank, or starts a sibling
/// item in that list. If a nested list is still the active destination, the
/// blank belongs to that nested list and the enclosing list stays tight.
fn resolveListBlankPending(
    containers: *std.ArrayList(ContainerState),
    matched: usize,
    line: source.Line,
    thematic_facts: *const ThematicLineFacts,
) void {
    const old_len = containers.items.len;
    const marker = tryListMarkerAfterLeafPrecedence(line, thematic_facts);

    var i = old_len;
    while (i > 0) {
        i -= 1;
        const state = &containers.items[i];
        if (state.node.tag != .list or !state.blank_pending) continue;

        // The list is closing before this line. A pending blank at the end of
        // a list does not make that list loose.
        if (i >= matched) {
            state.blank_pending = false;
            continue;
        }

        // A direct sibling marker follows the list itself when its item did
        // not match. This is a blank-separated item pair.
        if (i + 1 >= matched or containers.items[i + 1].node.tag != .list_item) {
            if (i + 1 == matched and marker != null and sameListType(state.node, marker.?)) {
                state.node.data.list.loose = true;
            }
            state.blank_pending = false;
            continue;
        }

        // The direct item matched and there is no nested container left on
        // the old stack: this line is a new direct block after the blank.
        if (matched == i + 2) {
            state.node.data.list.loose = true;
            state.blank_pending = false;
            continue;
        }

        // All nested containers matched, so the line remains inside the
        // nested structure and the blank belongs there.
        if (matched == old_len) {
            state.blank_pending = false;
            continue;
        }

        // A nested list remains matched while its item failed. A list marker
        // at the cursor is a sibling in that nested list; otherwise the
        // nested list is ending and the line resumes the outer item.
        if (matched > i + 2 and
            containers.items[matched - 1].node.tag == .list and
            marker != null)
        {
            state.blank_pending = false;
            continue;
        }

        state.node.data.list.loose = true;
        state.blank_pending = false;
    }
}

/// Is the remainder of a line paragraph continuation text (§5.1 laziness)?
/// That is, it does not start a block that can interrupt a paragraph:
/// a block quote marker, ATX heading, thematic break, or list item that can
/// interrupt (a blank-start item or an ordered item not starting at 1
/// cannot, §5.2 rule 1 exceptions). A Setext underline does not join this
/// predicate: it may transform only a paragraph at the same matched container
/// depth, never through a missing container marker.
fn isParagraphContinuationText(
    line: source.Line,
    thematic_facts: *const ThematicLineFacts,
) bool {
    if (tryStripBlockQuoteMarker(line) != null) return false;
    if (tryAtxHeading(line) != null) return false;
    if (tryFenceOpen(line) != null) return false;
    if (isThematicBreak(line, thematic_facts)) return false;
    if (tryListMarker(line)) |m| return !m.can_interrupt;
    return true;
}

/// A block whose inlines are parsed in phase 2, once every link reference
/// definition is known.
const PendingInline = union(enum) {
    paragraph: struct { node: *document.Node, lines: []const Paragraph.LineRef },
    heading: struct { node: *document.Node, span: source.Span },
    setext_heading: struct { node: *document.Node, lines: []const Paragraph.LineRef },
};

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

/// A link reference definition (§4.7): a label, an optional destination,
/// and an optional title. The destination and title spans are raw source
/// (backslash escapes resolved at emit time, like inline links).
const Definition = struct {
    dest: source.Span,
    title: ?source.Span,
};

/// The document's link reference definitions, keyed by *normalized* label
/// (see `normalizeLabel`). Keys are arena-owned copies. The first
/// definition for a label wins (§4.7: "If there are several matching
/// definitions, the first one takes precedence").
const Definitions = std.StringHashMap(Definition);

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

/// A recognized CommonMark §4.5 opening fence. `info` is the trimmed source
/// range after the fence; an empty range means no info string.
const FenceOpen = struct {
    marker: u8,
    fence_len: usize,
    indent: u8,
    info: source.Span,
};

/// The one open fenced-code leaf. Content is normalized incrementally into
/// the document arena; the node is appended at open time so container order
/// is fixed without buffering sibling blocks.
const FencedCode = struct {
    node: *document.Node,
    marker: u8,
    fence_len: usize,
    indent: u8,
    container_depth: usize,
    content: std.ArrayList(u8) = .empty,
};

fn tryFenceOpen(line: source.Line) ?FenceOpen {
    const text = line.text;
    var i: usize = 0;
    while (i < text.len and text[i] == ' ' and i < 4) : (i += 1) {}
    if (i > 3 or i >= text.len) return null;

    const indent: u8 = @intCast(i);
    const marker = text[i];
    if (marker != '`' and marker != '~') return null;
    const fence_start = i;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    const fence_len = i - fence_start;
    if (fence_len < 3) return null;

    // Backticks anywhere in a backtick fence's info string reject the whole
    // opener. Tilde info strings deliberately allow both marker characters.
    if (marker == '`' and std.mem.indexOfScalar(u8, text[i..], '`') != null) return null;

    var info_start = i;
    while (info_start < text.len and (text[info_start] == ' ' or text[info_start] == '\t')) : (info_start += 1) {}
    var info_end = text.len;
    while (info_end > info_start and (text[info_end - 1] == ' ' or text[info_end - 1] == '\t')) : (info_end -= 1) {}

    return .{
        .marker = marker,
        .fence_len = fence_len,
        .indent = indent,
        .info = .{
            .start = @intCast(line.start + info_start),
            .end = @intCast(line.start + info_end),
        },
    };
}

fn isFenceClose(line: source.Line, marker: u8, opening_len: usize) bool {
    const text = line.text;
    var i: usize = 0;
    while (i < text.len and text[i] == ' ' and i < 4) : (i += 1) {}
    if (i > 3 or i >= text.len or text[i] != marker) return false;

    const fence_start = i;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    if (i - fence_start < opening_len) return false;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i == text.len;
}

fn appendFencedContentLine(
    doc: *document.Document,
    fenced: *FencedCode,
    line: source.Line,
) ParseError!void {
    var strip: usize = 0;
    while (strip < fenced.indent and strip < line.text.len and line.text[strip] == ' ') : (strip += 1) {}
    try fenced.content.appendSlice(doc.allocator(), line.text[strip..]);
    try fenced.content.append(doc.allocator(), '\n');
}

/// Publishes the arena-backed normalized payload. No deinit is required: the
/// document arena owns both the content allocation and optional info copy.
fn finishFencedCode(fenced: *?FencedCode) void {
    const active = fenced.* orelse return;
    const info = active.node.data.code_block.info;
    active.node.data = .{ .code_block = .{
        .content = active.content.items,
        .info = info,
    } };
    fenced.* = null;
}

/// A Setext heading underline (§4.3): one or more `=` or `-` bytes, with up
/// to three leading spaces and only spaces/tabs after the marker run.
const SetextUnderline = struct {
    level: u8,
};

fn trySetextUnderline(line: source.Line) ?SetextUnderline {
    const text = line.text;
    var i: usize = 0;
    while (i < text.len and text[i] == ' ' and i < 4) : (i += 1) {}
    if (i > 3 or i >= text.len) return null;

    const marker = text[i];
    if (marker != '=' and marker != '-') return null;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    if (i != text.len) return null;
    return .{ .level = if (marker == '=') 1 else 2 };
}

/// Once-per-physical-line suffix facts for thematic-break recognition.
/// Container parsing advances only the line's start, so a query at any nested
/// view needs two facts per marker: the last non-whitespace byte of another
/// kind, and the third marker from the end. Both are computed in one reverse
/// scan and make every later suffix query constant-time.
const ThematicLineFacts = struct {
    last_other: [3]?usize,
    third_from_end: [3]?usize,

    fn init(line: source.Line) ThematicLineFacts {
        const markers = [_]u8{ '-', '_', '*' };
        var facts = ThematicLineFacts{
            .last_other = .{ null, null, null },
            .third_from_end = .{ null, null, null },
        };
        var seen = [_]u8{ 0, 0, 0 };

        for (0..line.text.len) |reverse_index| {
            const local = line.text.len - 1 - reverse_index;
            const byte = line.text[local];
            if (byte == ' ' or byte == '\t') continue;
            const absolute = line.start + local;
            for (markers, 0..) |marker, marker_index| {
                if (byte == marker) {
                    if (seen[marker_index] < 3) {
                        seen[marker_index] += 1;
                        if (seen[marker_index] == 3) {
                            facts.third_from_end[marker_index] = absolute;
                        }
                    }
                } else if (facts.last_other[marker_index] == null) {
                    facts.last_other[marker_index] = absolute;
                }
            }
        }
        return facts;
    }
};

/// A thematic break (§4.1): three or more matching `-`, `_`, or `*` bytes,
/// with up to three leading spaces and arbitrary spaces/tabs between or
/// after markers. No other byte is permitted.
fn isThematicBreak(line: source.Line, facts: *const ThematicLineFacts) bool {
    const text = line.text;
    var i: usize = 0;
    while (i < text.len and text[i] == ' ' and i < 4) : (i += 1) {}
    if (i > 3 or i >= text.len) return false;

    const marker = text[i];
    const marker_index: usize = switch (marker) {
        '-' => 0,
        '_' => 1,
        '*' => 2,
        else => return false,
    };
    const marker_start = line.start + i;
    if (facts.last_other[marker_index]) |last_other| {
        if (last_other >= marker_start) return false;
    }
    const third = facts.third_from_end[marker_index] orelse return false;
    return third >= marker_start;
}

/// Returns the first paragraph line that can become Setext heading content,
/// after leading link-reference definitions. Definitions alone are not
/// heading content (§4.7 examples 207/208), and a first content line with
/// more than three spaces of indentation is not eligible (§4.3).
fn setextContentIndex(doc: *document.Document, paragraph: ?Paragraph) ?usize {
    const p = paragraph orelse return null;
    const lines = p.lines.items;
    var k: usize = 0;
    while (k < lines.len) {
        const def = tryParseDefinition(doc, lines[k..]) orelse break;
        k += def.consumed_lines;
    }
    if (k == lines.len) return null;

    const first = doc.src.bytes[lines[k].content.start..lines[k].content.end];
    var indent: usize = 0;
    while (indent < first.len and first[indent] == ' ') : (indent += 1) {}
    if (indent > 3 or (indent < first.len and first[indent] == '\t')) return null;
    return k;
}

/// Converts the open paragraph to a Setext heading. Leading reference
/// definitions are registered exactly as they would be at normal paragraph
/// close; only the remaining lines become heading content. The heading span
/// covers the content lines plus the underline, while inline child spans
/// continue to point only at content bytes.
fn emitSetextHeading(
    doc: *document.Document,
    paragraph: *?Paragraph,
    underline_line: source.Line,
    underline: SetextUnderline,
    parent: *document.Node,
    defs: *Definitions,
    pending: *std.ArrayList(PendingInline),
) ParseError!bool {
    const k = setextContentIndex(doc, paragraph.*) orelse return false;
    const p = paragraph.*.?;

    var i: usize = 0;
    while (i < k) {
        const def = tryParseDefinition(doc, p.lines.items[i..]) orelse unreachable;
        try registerDefinition(doc, defs, def);
        i += def.consumed_lines;
    }

    const content = p.lines.items[k..];
    const node = try doc.createNode(.heading, .{
        .start = content[0].content.start,
        .end = @intCast(underline_line.content_end),
    }, .{ .heading = underline.level });
    try doc.appendChild(parent, node);
    try pending.append(doc.allocator(), .{
        .setext_heading = .{ .node = node, .lines = content },
    });
    paragraph.* = null;
    return true;
}

/// A parsed link reference definition (§4.7): the label content span and
/// the number of paragraph lines it consumed (the label may span lines).
const ParsedDefinition = struct {
    /// Content between the label's brackets.
    label: source.Span,
    /// Destination content span (sans `<...>` for the angle form).
    dest: source.Span,
    /// Title content span (sans delimiters), when present.
    title: ?source.Span,
    /// Lines consumed by the definition (label lines + destination/title
    /// lines), so the block pass can skip them.
    consumed_lines: usize,
};

/// Parses a link reference definition (§4.7) starting at the first line of
/// `lines`, whose contents may span lines. The grammar:
///
///     [label]: ws? dest ws? title?
///
/// where ws is spaces/tabs including up to one line ending, the label may
/// contain line endings (spec example 202), the destination may not, and
/// the title may. "No further character may occur" after the title (or
/// destination when there is no title) — the definition ends at the end of
/// that line. Returns null when the lines are not a definition (in which
/// case the whole paragraph is ordinary text: definitions cannot interrupt
/// a paragraph, §4.7 example 204).
fn tryParseDefinition(doc: *document.Document, lines: []const Paragraph.LineRef) ?ParsedDefinition {
    const bytes = doc.src.bytes;
    const para_end = lines[lines.len - 1].content.end;

    // Optional indentation: up to three spaces (a tab disqualifies the
    // line — full tab-stop handling is deferred, as in ATX headings).
    var i: usize = 0;
    var indent: usize = 0;
    while (i < lines[0].content.len() and bytes[lines[0].content.start + i] == ' ') : (i += 1) {
        indent += 1;
    }
    if (indent > 3) return null;
    if (i < lines[0].content.len() and bytes[lines[0].content.start + i] == '\t') return null;

    // The label: `[` ... first unescaped `]` (may span lines).
    const label = scanDefinitionLabel(bytes, lines, i) orelse return null;

    // The colon, then ws (spaces/tabs including up to one line ending).
    var cur = label.after;
    if (!hasByte(bytes, para_end, cur, ':')) return null;
    cur += 1;
    const after_colon = skipDefWs(bytes, lines, cur, para_end) orelse return null;

    // The destination: angle or bare, on the current line (destinations
    // cannot contain line endings).
    var dest: source.Span = undefined;
    var p = after_colon;
    if (p < para_end and bytes[p] == '<') {
        const end = scanAngleDest(bytes, p + 1, lineEnd(bytes, lines, p)) orelse return null;
        dest = .{ .start = @intCast(p + 1), .end = @intCast(end) };
        p = end + 1;
    } else {
        const end = scanBareDest(bytes, p, lineEnd(bytes, lines, p)) orelse return null;
        dest = .{ .start = @intCast(p), .end = @intCast(end) };
        p = end;
    }

    // After the destination: optional ws, then an optional title, then end
    // of line. The title must be *separated* from the destination by spaces
    // or tabs (§4.7: `[foo]: <bar>(baz)` is not a definition, because
    // `(baz)` follows the destination with no separating whitespace).
    var title: ?source.Span = null;
    var end_line_end: usize = undefined;
    var q = p;
    const dest_line_end = lineEnd(bytes, lines, p);
    while (q < dest_line_end and (bytes[q] == ' ' or bytes[q] == '\t')) q += 1;

    if (q < dest_line_end) {
        // A title opens on the destination's line. A title opener that
        // fails to parse as a complete title (unclosed, or followed by
        // non-whitespace) invalidates the whole definition: "No further
        // character may occur."
        if (bytes[q] != '"' and bytes[q] != '\'' and bytes[q] != '(') return null;
        const t = scanTitle(bytes, q, para_end) orelse return null;
        title = t.content;
        q = t.end;
        end_line_end = lineEnd(bytes, lines, q);
        while (q < end_line_end) : (q += 1) {
            if (bytes[q] != ' ' and bytes[q] != '\t') return null;
        }
    } else if (nextLineStart(lines, q)) |next_start| {
        // End of the destination's line: the title, if any, begins on the
        // next line (the line ending is itself the separator). A failed
        // title attempt leaves the definition without a title and does not
        // consume the next line (§4.7 example: `[foo]: /url\n"title" ok`
        // is the definition `[foo]: /url` followed by a paragraph).
        var n = next_start;
        const n_end = lineEnd(bytes, lines, n);
        while (n < n_end and (bytes[n] == ' ' or bytes[n] == '\t')) n += 1;
        if (n < n_end and (bytes[n] == '"' or bytes[n] == '\'' or bytes[n] == '(')) {
            if (scanTitle(bytes, n, para_end)) |t| {
                var q2 = t.end;
                const t_line_end = lineEnd(bytes, lines, q2);
                var clean = true;
                while (q2 < t_line_end) : (q2 += 1) {
                    if (bytes[q2] != ' ' and bytes[q2] != '\t') {
                        clean = false;
                        break;
                    }
                }
                if (clean) {
                    title = t.content;
                    end_line_end = t_line_end;
                } else {
                    end_line_end = dest_line_end;
                }
            } else {
                end_line_end = dest_line_end;
            }
        } else {
            end_line_end = dest_line_end;
        }
    } else {
        // Destination on the last line, nothing after it.
        end_line_end = dest_line_end;
    }

    return .{
        .label = label.content,
        .dest = dest,
        .title = title,
        .consumed_lines = consumedLines(bytes, lines, end_line_end),
    };
}

/// Registers a parsed definition; the first definition for a label wins
/// (§4.7: "If there are several matching definitions, the first one takes
/// precedence"). The normalized label is arena-owned.
fn registerDefinition(doc: *document.Document, defs: *Definitions, def: ParsedDefinition) ParseError!void {
    const key = try normalizeLabel(doc, def.label);
    const gop = try defs.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .dest = def.dest, .title = def.title };
    }
}

/// The result of scanning a definition's label.
const ScannedLabel = struct {
    /// Content between the brackets.
    content: source.Span,
    /// Position just past the closing `]`.
    after: usize,
};

/// Scans a link label (§6.3): `[` ... first `]` not backslash-escaped,
/// with no unescaped brackets inside, at least one non-whitespace
/// character, at most 999 characters. The label may span lines (line
/// endings are content, later normalized away). Returns null when the text
/// is not a valid label.
fn scanDefinitionLabel(bytes: []const u8, lines: []const Paragraph.LineRef, start: usize) ?ScannedLabel {
    if (start >= lines[0].content.len()) return null;
    const first = lines[0].content.start + start;
    if (bytes[first] != '[') return null;
    const para_end = lines[lines.len - 1].content.end;

    var p = first + 1;
    var has_nonspace = false;
    var count: usize = 0;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ']' and !isEscaped(bytes, p)) {
            if (!has_nonspace) return null;
            return .{ .content = .{ .start = @intCast(first + 1), .end = @intCast(p) }, .after = p + 1 };
        }
        if (b == '[' and !isEscaped(bytes, p)) return null; // unescaped bracket inside
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') has_nonspace = true;
        count += 1;
        if (count > 999) return null; // §6.3: at most 999 characters
    }
    return null;
}

/// The byte at absolute position `pos` is `ch`? (`pos` may be past the end
/// of its line's content but within the paragraph — the colon after a
/// label spanning lines is on the label's last line.)
fn hasByte(bytes: []const u8, para_end: usize, pos: usize, ch: u8) bool {
    return pos < para_end and bytes[pos] == ch;
}

/// Skips definition whitespace (§4.7): spaces/tabs, including up to one
/// line ending. Returns the position after the whitespace, or null when two
/// line endings (or a blank line) appear — the block pass splits paragraphs
/// on blank lines, so this also bounds the scan.
fn skipDefWs(bytes: []const u8, lines: []const Paragraph.LineRef, start: usize, para_end: usize) ?usize {
    _ = lines;
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

/// The end of the line whose content contains absolute position `pos` (the
/// last line's content end if `pos` is past everything). Line contents are
/// disjoint with terminators between them, so this is the byte just before
/// the next line's content.
fn lineEnd(bytes: []const u8, lines: []const Paragraph.LineRef, pos: usize) usize {
    _ = bytes;
    var end = lines[0].content.end;
    for (lines) |ref| {
        if (ref.content.start <= pos) end = ref.content.end;
    }
    return end;
}

/// The content start of the line after the one containing `pos`, or null
/// when `pos` is on the last line.
fn nextLineStart(lines: []const Paragraph.LineRef, pos: usize) ?usize {
    var cur: usize = 0;
    for (lines, 0..) |ref, k| {
        if (ref.content.start <= pos) cur = k;
    }
    if (cur + 1 >= lines.len) return null;
    return lines[cur + 1].content.start;
}

/// Lines consumed by a definition ending at `line_end`: one for each line
/// whose content starts before that position.
fn consumedLines(bytes: []const u8, lines: []const Paragraph.LineRef, line_end: usize) usize {
    _ = bytes;
    var n: usize = 0;
    for (lines) |ref| {
        if (ref.content.start >= line_end) break;
        n += 1;
    }
    return n;
}

/// Normalizes a label (§6.3): strip the brackets (the caller passes the
/// content span), perform the Unicode case fold, strip leading and trailing
/// spaces/tabs/line endings, and collapse consecutive internal
/// spaces/tabs/line endings to a single space. The result is an
/// arena-owned copy — folds can expand (e.g. ẞ -> ss), so it cannot borrow
/// the source.
fn normalizeLabel(doc: *document.Document, content: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;

    // Pass 1: folded length (case folds expand to at most three code
    // points; each of those is at most four UTF-8 bytes).
    var n: usize = 0;
    var i: usize = content.start;
    while (i < content.end) {
        const cp = unicode.decode(bytes, i) orelse bytes[i];
        const f = unicode.caseFold(cp);
        for (0..f.len) |j| n += utf8Len(f.chars[j]);
        i += if (unicode.decode(bytes, i)) |_| unicodeCpLen(bytes, i) else 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = content.start;
    while (i < content.end) {
        const cp = unicode.decode(bytes, i) orelse bytes[i];
        const f = unicode.caseFold(cp);
        for (0..f.len) |j| k += encodeCp(buf[k..], f.chars[j]);
        i += if (unicode.decode(bytes, i)) |_| unicodeCpLen(bytes, i) else 1;
    }

    // Strip leading/trailing whitespace (space, tab, line ending) and
    // collapse consecutive internal runs to a single space.
    var start: usize = 0;
    while (start < n and isLabelWs(buf[start])) start += 1;
    var end = n;
    while (end > start and isLabelWs(buf[end - 1])) end -= 1;
    var out: usize = 0;
    var prev_ws = false;
    for (buf[start..end]) |b| {
        if (isLabelWs(b)) {
            if (!prev_ws) {
                buf[out] = ' ';
                out += 1;
                prev_ws = true;
            }
        } else {
            buf[out] = b;
            out += 1;
            prev_ws = false;
        }
    }
    return buf[0..out];
}

fn isLabelWs(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// UTF-8 encoded length of a code point.
fn utf8Len(cp: u21) usize {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

/// Byte length of the UTF-8 sequence at position `i`.
fn unicodeCpLen(bytes: []const u8, i: usize) usize {
    const b = bytes[i];
    return if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
}

/// Encodes a code point as UTF-8 into `out[0..]`; returns bytes written.
fn encodeCp(out: []u8, cp: u21) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Closes a paragraph (phase 1). Leading lines that parse as link reference
/// definitions (§4.7) are extracted and registered; the remaining lines
/// form the paragraph node. A paragraph consisting entirely of definitions
/// produces no block at all ("no visible content"). Definitions cannot
/// interrupt a paragraph — only a paragraph *starting* with them is
/// partially or wholly a definition — so extraction stops at the first
/// non-definition line. Inline parsing is deferred to phase 2, where the
/// complete definitions map is available.
fn closeParagraph(
    doc: *document.Document,
    paragraph: *?Paragraph,
    parent: *document.Node,
    defs: *Definitions,
    pending: *std.ArrayList(PendingInline),
) ParseError!void {
    const p = paragraph.* orelse return;
    paragraph.* = null;

    const lines = p.lines.items;

    // Extract leading link reference definitions.
    var k: usize = 0;
    while (k < lines.len) {
        const def = tryParseDefinition(doc, lines[k..]) orelse break;
        try registerDefinition(doc, defs, def);
        k += def.consumed_lines;
    }
    if (k == lines.len) return; // entirely definitions: no block

    const remaining = lines[k..];
    const span = source.Span{
        .start = remaining[0].content.start,
        .end = remaining[remaining.len - 1].content.end,
    };
    const node = try doc.createNode(.paragraph, span, .none);
    try doc.appendChild(parent, node);
    try pending.append(doc.allocator(), .{ .paragraph = .{ .node = node, .lines = remaining } });
}

/// Phase 2 inline pass for a paragraph: discovery -> scan -> link discovery
/// -> match, now with the full definitions map.
fn parseParagraphInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
) ParseError!void {
    return parseMultilineBlockInlines(doc, node, lines, defs);
}

/// Phase 2 inline pass for Setext content. The underline itself is never part
/// of the inline input; the shared inline line-joining rules remove leading
/// spaces/tabs from every continuation line.
fn parseSetextHeadingInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
) ParseError!void {
    return parseMultilineBlockInlines(doc, node, lines, defs);
}

fn parseMultilineBlockInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
) ParseError!void {
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());

    // Discovery runs before scanning: code spans and raw HTML tags may span
    // lines, and their content is opaque to the delimiter/escape/break
    // processing. Both are discovered over the whole paragraph, then merged
    // into one resolved construct list (first-come precedence).
    var contents = try doc.allocator().alloc(source.Span, lines.len);
    defer doc.allocator().free(contents);
    for (lines, 0..) |ref, i| contents[i] = ref.content;
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, contents, &spans);
    var tags = std.ArrayList(HtmlTag).empty;
    defer tags.deinit(doc.allocator());
    try discoverHtmlTags(doc, contents, &tags);
    var constructs = std.ArrayList(Construct).empty;
    defer constructs.deinit(doc.allocator());
    try mergeConstructs(doc, spans.items, tags.items, &constructs);

    // A construct consumed by an autolink (first-come at the `<`) is dead
    // for the whole paragraph, including lines scanned later; `exclude` is
    // the shared floor for the per-line scans.
    var exclude: u32 = 0;
    for (lines, 0..) |ref, i| {
        const has_following_content_line = i + 1 < lines.len;
        const end = analyzeLineEnd(doc.src.bytes, ref.content, has_following_content_line);
        const start = skipLeadingWhitespace(doc.src.bytes, ref.content);
        try scanLine(doc, &items, ref.content, .{ .start = start, .end = end.content_end }, constructs.items, &exclude);
        if (has_following_content_line) {
            // A line ending inside a construct (code span content — §6.1
            // "line endings are converted to spaces" — or a raw HTML tag)
            // is construct content, never a break: hard line breaks do not
            // occur inside code spans or HTML tags (§6.1/§6.6).
            if (!terminatorInsideConstruct(ref.terminator, constructs.items)) {
                try items.append(doc.allocator(), .{ .brk = .{ .kind = end.kind, .span = ref.terminator } });
            }
        }
    }
    // Second discovery pass: inline links, images, and reference links
    // (§6.3/§6.4), before emphasis matching.
    const para_end = lines[lines.len - 1].content.end;
    try discoverLinksAndImages(doc, &items, para_end, defs);
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

fn emitHeading(
    doc: *document.Document,
    line: source.Line,
    heading: AtxHeading,
    parent: *document.Node,
    pending: *std.ArrayList(PendingInline),
) ParseError!void {
    const node = try doc.createNode(.heading, line.contentSpan(), .{
        .heading = heading.level,
    });
    try doc.appendChild(parent, node);
    if (!heading.content.isEmpty()) {
        try pending.append(doc.allocator(), .{ .heading = .{ .node = node, .span = heading.content } });
    }
}

/// Phase 2 inline pass for a heading (see `emitHeading`).
fn parseHeadingInlines(
    doc: *document.Document,
    node: *document.Node,
    content: source.Span,
    defs: *Definitions,
) ParseError!void {
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, &[_]source.Span{content}, &spans);
    var tags = std.ArrayList(HtmlTag).empty;
    defer tags.deinit(doc.allocator());
    try discoverHtmlTags(doc, &[_]source.Span{content}, &tags);
    var constructs = std.ArrayList(Construct).empty;
    defer constructs.deinit(doc.allocator());
    try mergeConstructs(doc, spans.items, tags.items, &constructs);
    var exclude: u32 = 0;
    try scanLine(doc, &items, content, content, constructs.items, &exclude);
    try discoverLinksAndImages(doc, &items, content.end, defs);
    try matchInlines(doc, node, items.items);
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
/// backslash before a following content line is a hard break; otherwise the
/// break is soft. Tabs in the trailing run do not trigger a hard break. The
/// entire trailing run is consumed in every case. A final backslash with no
/// following content line stays literal (example 644, and Setext §4.3).
fn analyzeLineEnd(bytes: []const u8, span: source.Span, has_following_content_line: bool) LineEnd {
    var end = span.end;
    var spaces: usize = 0;
    while (end > span.start and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) : (end -= 1) {
        if (bytes[end - 1] == ' ') spaces += 1;
    }
    const trailing = span.end - end;
    if (has_following_content_line and
        trailing == 0 and
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

/// A recognized autolink (§6.8). `span` covers `<...>`; `content` is the
/// bytes between the angle brackets, verbatim (backslash escapes are inert
/// inside autolinks); `is_email` selects the `mailto:` href prefix.
const AutolinkScan = struct {
    span: source.Span,
    content: source.Span,
    is_email: bool,
};

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
    /// A discovered inline image (§6.7): `span` covers the whole construct
    /// `![desc](dest "title")`; `children` are the description items (an
    /// image description may contain links and images, so unlike a link
    /// these may contain link/image items); `dest`/`title` are raw source
    /// spans like a link's. The description is flattened to the `alt`
    /// string at emit time (docs/IMAGES-PARSING.md §3).
    image: ImageItem,
    /// A recognized autolink (§6.8): `span` covers `<...>`, `content` the
    /// bytes between the angle brackets (verbatim — backslash escapes are
    /// inert inside autolinks), `is_email` selects the `mailto:` href
    /// prefix. Opaque to the delimiter stack and link discovery, like
    /// `code_span` (docs/AUTOLINKS.md §2).
    autolink: AutolinkScan,
    /// A recognized raw HTML tag (§6.6): `span` covers the whole construct
    /// (`<` .. `>`), which may span lines. Opaque to the delimiter stack,
    /// link discovery, and break processing (docs/RAW-HTML.md §2); the
    /// renderer writes the source bytes verbatim.
    raw_html: RawHtmlItem,
};

/// A raw HTML tag item (§6.6): the whole construct span. The tag's bytes
/// are rendered verbatim from the source, so no payload is needed.
const RawHtmlItem = struct {
    span: source.Span,
};

/// A discovered inline link (§6.6). See `InlineItem.link`.
const LinkItem = struct {
    span: source.Span,
    children: std.ArrayList(InlineItem),
    dest: source.Span,
    title: ?source.Span,
};

/// A discovered inline image (§6.7). See `InlineItem.image`.
const ImageItem = struct {
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
        .image => |im| im.span,
        .autolink => |a| a.span,
        .raw_html => |h| h.span,
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
        .image => |*im| im.span = span,
        .autolink => |*a| a.span = span,
        .raw_html => |*h| h.span = span,
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

/// A raw HTML tag discovered by `discoverHtmlTags` (§6.6). Spans are
/// disjoint (each match consumes its whole construct) and sorted by
/// `span.start`.
const HtmlTag = struct {
    /// `<` .. `>` of the whole construct, including any line endings.
    span: source.Span,
};

/// A paragraph-level opaque inline construct: a code span or a raw HTML
/// tag, resolved for first-come precedence. `mergeConstructs` drops any
/// construct that starts inside an already-accepted one, so the list is
/// disjoint and sorted by `span.start`. The scan consumes constructs in
/// order; everything inside them is opaque to the delimiter stack, link
/// discovery, and break processing.
const Construct = struct {
    kind: enum { code_span, html_tag },
    span: source.Span,
    /// Code spans: the raw content bounds (see `CodeSpan.content`).
    /// Unused for HTML tags.
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

/// True if the line terminator `[term.start, term.end)` lies inside a
/// resolved construct (code span content or raw HTML tag) that continues on
/// a later line. Used to suppress break items: the line ending is then
/// construct content, not a soft/hard break. The resolved list already
/// dropped first-come losers, so a terminator inside a dead span is a
/// normal break.
fn terminatorInsideConstruct(term: source.Span, constructs: []const Construct) bool {
    for (constructs) |c| {
        if (c.span.start > term.start) return false; // sorted; later constructs are past it
        if (term.start < c.span.end) return true;
    }
    return false;
}

/// Merges the discovered code spans and HTML tags into one resolved,
/// overlap-free list ordered by start. First-come wins: a construct whose
/// start lies inside an already-accepted construct's span is dropped (the
/// earlier construct's opener precedes it, so per §6.1 the earlier
/// construct is parsed and the later one never starts). Both input lists
/// are sorted and internally disjoint, so a linear walk suffices
/// (docs/RAW-HTML.md §2).
fn mergeConstructs(
    doc: *document.Document,
    spans: []const CodeSpan,
    tags: []const HtmlTag,
    out: *std.ArrayList(Construct),
) ParseError!void {
    var si: usize = 0;
    var ti: usize = 0;
    var last_end: u32 = 0;
    while (si < spans.len or ti < tags.len) {
        const span_next = si < spans.len;
        const tag_next = ti < tags.len;
        const from_tag = if (!span_next) true else if (!tag_next) false else tags[ti].span.start < spans[si].span.start;
        if (from_tag) {
            if (tags[ti].span.start >= last_end) {
                try out.append(doc.allocator(), .{
                    .kind = .html_tag,
                    .span = tags[ti].span,
                    .content = .{ .start = 0, .end = 0 },
                });
                last_end = tags[ti].span.end;
            }
            ti += 1;
        } else {
            if (spans[si].span.start >= last_end) {
                try out.append(doc.allocator(), .{
                    .kind = .code_span,
                    .span = spans[si].span,
                    .content = spans[si].content,
                });
                last_end = spans[si].span.end;
            }
            si += 1;
        }
    }
}

/// Discovers raw HTML tags (§6.6) over the concatenated raw content of the
/// given spans (one entry per line of the block). The scan is escape-aware
/// at the `<` only: `\<` is literal, and backslash escapes are inert
/// *inside* tags, so a matched construct is consumed wholesale. A construct
/// that fails leaves its `<` alone — it may still be an autolink (§6.8) or
/// literal text, resolved later in the scan.
fn discoverHtmlTags(doc: *document.Document, contents: []const source.Span, tags: *std.ArrayList(HtmlTag)) ParseError!void {
    const bytes = doc.src.bytes;
    const para_start = contents[0].start;
    const para_end = contents[contents.len - 1].end;
    var i = para_start;
    while (i < para_end) {
        if (bytes[i] == '<' and !isEscaped(bytes, i)) {
            if (scanHtmlTag(bytes, i, para_end)) |span| {
                try tags.append(doc.allocator(), .{ .span = span });
                i = span.end;
                continue;
            }
        }
        i += 1;
    }
}

/// Scans a raw HTML construct (§6.6) starting at the `<` at `pos`, bounded
/// by `end` (the paragraph end — tags may span lines). Tries the six
/// construct forms in spec order; returns the construct span or null.
fn scanHtmlTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 2 > end or bytes[pos] != '<') return null;
    // `<!--` comment (`<!-->`, `<!--->`, or `<!--` ... `-->`).
    if (pos + 4 <= end and bytes[pos + 1] == '!' and bytes[pos + 2] == '-' and bytes[pos + 3] == '-') {
        return scanComment(bytes, pos, end);
    }
    if (bytes[pos + 1] == '?') return scanProcessingInstruction(bytes, pos, end);
    if (bytes[pos + 1] == '!') {
        // CDATA before the declaration form: `<![CDATA[` does not match
        // `<!` + letter, so the order is a matter of clarity, not behavior.
        if (pos + 9 <= end and std.mem.startsWith(u8, bytes[pos..end], "<![CDATA[")) {
            return scanCdata(bytes, pos, end);
        }
        return scanDeclaration(bytes, pos, end);
    }
    if (bytes[pos + 1] == '/') return scanClosingTag(bytes, pos, end);
    return scanOpenTag(bytes, pos, end);
}

/// §6.6 whitespace chunk: spaces/tabs, at most one line ending, then
/// spaces/tabs again ("optional spaces, tabs, and up to one line ending").
/// Returns the position after, or null when a second consecutive line
/// ending appears (which fails the containing tag).
fn skipTagWhitespace(bytes: []const u8, i: usize, end: usize) ?usize {
    var p = i;
    while (p < end and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
    if (p < end and lineEndingLen(bytes, p) > 0) {
        p += lineEndingLen(bytes, p);
        while (p < end and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
        if (p < end and lineEndingLen(bytes, p) > 0) return null;
    }
    return p;
}

/// `<!-->` (5 bytes) or `<!--->` (6 bytes), or the general form
/// `<!--` + (no `-->`) + `-->`.
fn scanComment(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 5 <= end and bytes[pos + 4] == '>') {
        return .{ .start = @intCast(pos), .end = @intCast(pos + 5) }; // <!-->
    }
    if (pos + 6 <= end and bytes[pos + 4] == '-' and bytes[pos + 5] == '>') {
        return .{ .start = @intCast(pos), .end = @intCast(pos + 6) }; // <!--->
    }
    var j = pos + 4;
    while (j + 2 < end) : (j += 1) {
        if (bytes[j] == '-' and bytes[j + 1] == '-' and bytes[j + 2] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 3) };
        }
    }
    return null;
}

/// `<?` + (no `?>`) + `?>`.
fn scanProcessingInstruction(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var j = pos + 2;
    while (j + 1 < end) : (j += 1) {
        if (bytes[j] == '?' and bytes[j + 1] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 2) };
        }
    }
    return null;
}

/// `<!` + ASCII letter + (no `>`) + `>`.
fn scanDeclaration(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 3 > end or !isAsciiLetter(bytes[pos + 2])) return null;
    var j = pos + 3;
    while (j < end) : (j += 1) {
        if (bytes[j] == '>') return .{ .start = @intCast(pos), .end = @intCast(j + 1) };
    }
    return null;
}

/// `<![CDATA[` + (no `]]>`) + `]]>`.
fn scanCdata(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var j = pos + 9;
    while (j + 2 < end) : (j += 1) {
        if (bytes[j] == ']' and bytes[j + 1] == ']' and bytes[j + 2] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 3) };
        }
    }
    return null;
}

/// `</` + tag name + whitespace chunk + `>` (no attributes, no `/`).
fn scanClosingTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var p = pos + 2;
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    p += 1;
    while (p < end and isTagNameChar(bytes[p])) : (p += 1) {}
    const w = skipTagWhitespace(bytes, p, end) orelse return null;
    if (w < end and bytes[w] == '>') return .{ .start = @intCast(pos), .end = @intCast(w + 1) };
    return null;
}

/// §6.6 unquoted attribute value terminator set: whitespace, `"`, `'`, `=`,
/// `<`, `>`, or `` ` ``.
fn isUnquotedValueStop(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or
        b == '"' or b == '\'' or b == '=' or b == '<' or b == '>' or b == '`';
}

/// `<` + tag name + zero or more attributes + whitespace chunk + optional
/// `/` + `>`. Each attribute is a whitespace chunk, an attribute name, and
/// an optional value specification (whitespace chunk + `=` + whitespace
/// chunk + value), where a value is unquoted (nonempty), single-quoted, or
/// double-quoted.
fn scanOpenTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var p = pos + 1;
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    p += 1;
    while (p < end and isTagNameChar(bytes[p])) : (p += 1) {}
    // Attributes and tail. Each component boundary is a whitespace chunk
    // (spaces/tabs and at most one line ending) followed by `>`, `/`+`>`,
    // or an attribute name. An attribute name must be preceded by at least
    // one whitespace byte: the spec attaches the chunk to the attribute,
    // spec example 622 (`<a href='bar'title=title>`) fails without it, and
    // `<a:b>` must fall through to the autolink attempt. The chunk probed
    // after an attribute name doubles as the next component's boundary
    // chunk when no `=` follows, so the scan tracks whether a boundary was
    // already consumed and whether it was nonempty.
    var boundary_done = false;
    var boundary_nonempty = false;
    while (true) {
        var chunk: usize = undefined;
        var nonempty: bool = undefined;
        if (boundary_done) {
            chunk = p;
            nonempty = boundary_nonempty;
            boundary_done = false;
        } else {
            chunk = skipTagWhitespace(bytes, p, end) orelse return null;
            nonempty = chunk != p;
        }
        if (chunk >= end) return null;
        const b = bytes[chunk];
        if (b == '>') return .{ .start = @intCast(pos), .end = @intCast(chunk + 1) };
        if (b == '/') {
            // The optional `/` must be immediately before `>` (`<a/ >` fails).
            if (chunk + 1 < end and bytes[chunk + 1] == '>') return .{ .start = @intCast(pos), .end = @intCast(chunk + 2) };
            return null;
        }
        // Attribute name: letter/`_`/`:` first, then name chars.
        if (!(isAsciiLetter(b) or b == '_' or b == ':')) return null;
        if (!nonempty) return null; // attributes require preceding whitespace
        var q = chunk + 1;
        while (q < end and isAttrNameChar(bytes[q])) : (q += 1) {}
        // Optional value specification: a whitespace chunk, then `=`.
        const eq = skipTagWhitespace(bytes, q, end) orelse return null;
        if (eq < end and bytes[eq] == '=') {
            const vstart = skipTagWhitespace(bytes, eq + 1, end) orelse return null;
            if (vstart >= end) return null;
            const v = bytes[vstart];
            if (v == '"' or v == '\'') {
                // Quoted value: scan to the closing quote (may contain line
                // endings and any other bytes; backslash is not special).
                var r = vstart + 1;
                while (r < end and bytes[r] != v) : (r += 1) {}
                if (r >= end) return null; // unterminated
                p = r + 1;
            } else {
                // Unquoted value: a nonempty run of non-terminator chars.
                var r = vstart;
                while (r < end and !isUnquotedValueStop(bytes[r])) : (r += 1) {}
                if (r == vstart) return null; // empty unquoted value
                p = r;
            }
        } else {
            // No value spec: the probe chunk is the next component's
            // boundary chunk, already consumed.
            p = eq;
            boundary_done = true;
            boundary_nonempty = eq != q;
        }
    }
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

/// Discovers inline links and images (§6.6/§6.7) and reference links
/// (§6.6 reference forms) in the item list, restructuring it in place.
/// Walks the list with a bracket stack; on a `]` whose nearest `[` or `![`
/// opener is followed by a valid `(...)` construct in the source, or whose
/// nearest `[` is followed by a reference label (full/collapsed/shortcut)
/// with a matching definition, splices the bracket range — plus the items
/// covering the consumed `(...)`/label bytes — into a single `link` or
/// `image` item whose children are the bracket-range items, and drops the
/// matched opener and everything trapped above it. Brackets that never form
/// a construct stay in the list and emit as literal text.
///
/// Nesting follows the spec appendix's *look for link or image*: a formed
/// *link* inactivates every earlier `[` opener (links cannot contain links,
/// innermost wins), while a formed *image* inactivates nothing (an image
/// description may contain links and images). Inactivity is decided by a
/// monotone check — a `[` at out position `p` is inactive iff some link has
/// formed with an opener at a larger out position, so nothing is re-marked
/// and matching stays linear (docs/IMAGES-PARSING.md §2). `![` openers are
/// never inactive. Reference precedence (§6.6): an inline link (`(...)`),
/// then full (`[text][label]`), then collapsed (`[text][]`), then shortcut
/// (`[text]`); a failed inline `(...)` does not block the shortcut form
/// (spec example 561). Reference forms apply to both `[` and `![` openers
/// (reference-style images per docs/REFERENCE-IMAGES.md). Runs
/// before emphasis matching: link/image items are opaque to the delimiter
/// stack, and their children are matched separately (link text as a fresh
/// inline scope; image descriptions flattened to the alt string at emit
/// time).
fn discoverLinksAndImages(doc: *document.Document, items: *std.ArrayList(InlineItem), para_end: u32, defs: *Definitions) ParseError!void {
    const bytes = doc.src.bytes;
    var out = std.ArrayList(InlineItem).empty;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(doc.allocator());

    const old = items.items;
    var max_link_opener_out: usize = 0;
    var i: usize = 0;
    while (i < old.len) : (i += 1) {
        const item = old[i];
        if (item == .bracket and (item.bracket.ch == '[' or item.bracket.ch == '!')) {
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
            if (out.items[o].bracket.ch == '[' and max_link_opener_out > o) {
                // Inactive opener (a `[` below a formed link): remove it
                // and return a literal `]` — it must not reach a `![`
                // below it (spec appendix; docs/IMAGES-PARSING.md §2).
                _ = stack.pop();
                try out.append(doc.allocator(), item);
                continue;
            }
            const close_end = item.bracket.span.end;
            const is_image = out.items[o].bracket.ch == '!';
            const open_start = out.items[o].bracket.span.start;

            // The bracket text span: between the opener and this `]`. A `[`
            // opener is one byte; a `![` opener spans two, so the text
            // starts past the bang. Used for collapsed/shortcut labels and
            // as the link text for image alt-flattening inputs.
            const text = source.Span{ .start = open_start + (if (is_image) @as(u32, 2) else 1), .end = close_end - 1 };

            // 1. Inline link/image: `(` immediately after the `]`.
            if (close_end < para_end and bytes[close_end] == '(') {
                if (tryParseLink(bytes, close_end, para_end)) |lp| {
                    // Children: the items between the opener and `]`. Never
                    // contains a link (one would have killed this opener
                    // first); an image's description may contain links and
                    // images.
                    var children = std.ArrayList(InlineItem).empty;
                    try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                    // Consume the `(...)` items: everything after the `]` up
                    // to (not including) the closing paren. The last
                    // consumed item may extend past the closing paren (e.g.
                    // `[foo](/uri) and more`) — truncate it so its tail
                    // stays literal text after the construct.
                    var j = i + 1;
                    while (j < old.len and itemSpan(old[j]).start < lp.paren_end) : (j += 1) {}
                    if (itemSpan(old[j - 1]).end > lp.paren_end) {
                        setItemSpan(&old[j - 1], .{ .start = lp.paren_end, .end = itemSpan(old[j - 1]).end });
                        try out.append(doc.allocator(), old[j - 1]);
                    }

                    out.shrinkRetainingCapacity(o);
                    if (is_image) {
                        try out.append(doc.allocator(), .{
                            .image = .{
                                .span = .{ .start = open_start, .end = lp.paren_end },
                                .children = children,
                                .dest = lp.dest,
                                .title = lp.title,
                            },
                        });
                    } else {
                        try out.append(doc.allocator(), .{
                            .link = .{
                                .span = .{ .start = open_start, .end = lp.paren_end },
                                .children = children,
                                .dest = lp.dest,
                                .title = lp.title,
                            },
                        });
                        // A formed link inactivates every earlier `[` (the
                        // monotone check above); record its out position so
                        // those openers are recognized as dead.
                        max_link_opener_out = @max(max_link_opener_out, o);
                    }
                    // The matched opener and everything trapped above it
                    // were consumed by the construct; entries below stay
                    // (their activity is decided by the monotone check).
                    while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                    i = j - 1; // the `(...)` items were consumed
                    continue;
                }
                // A `(` that fails to parse as an inline construct falls
                // through to the reference forms below (§6.6 example:
                // `[foo](not a link)` with `[foo]: /url1` → shortcut
                // reference, with `(not a link)` as literal text).
            }

            // 2. Reference forms: a `[` immediately after the `]` is a full
            // or collapsed reference; nothing else is a shortcut. Applies to
            // both links and images (spec appendix: the procedure is
            // uniform; reference-style images per docs/REFERENCE-IMAGES.md).
            if (close_end < para_end and bytes[close_end] == '[') {
                // Collapsed: `[]` — the label is the bracket text itself.
                if (close_end + 1 < para_end and bytes[close_end + 1] == ']') {
                    if (try tryResolveReference(doc, defs, text)) |def| {
                        var children = std.ArrayList(InlineItem).empty;
                        try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                        var j = i + 1;
                        while (j < old.len and itemSpan(old[j]).start < close_end + 2) : (j += 1) {}
                        if (itemSpan(old[j - 1]).end > close_end + 2) {
                            setItemSpan(&old[j - 1], .{ .start = close_end + 2, .end = itemSpan(old[j - 1]).end });
                            try out.append(doc.allocator(), old[j - 1]);
                        }

                        out.shrinkRetainingCapacity(o);
                        if (is_image) {
                            try out.append(doc.allocator(), .{
                                .image = .{
                                    .span = .{ .start = open_start, .end = close_end + 2 },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                        } else {
                            try out.append(doc.allocator(), .{
                                .link = .{
                                    .span = .{ .start = open_start, .end = close_end + 2 },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                            max_link_opener_out = @max(max_link_opener_out, o);
                        }
                        while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                        i = j - 1;
                        continue;
                    }
                    // An unresolved `[]` still blocks the shortcut form.
                    _ = stack.pop();
                    try out.append(doc.allocator(), item);
                    continue;
                }

                // Full: `[label]` — the label is scanned and resolved.
                if (scanRefLabel(bytes, close_end, para_end)) |lab| {
                    if (try tryResolveReference(doc, defs, lab.content)) |def| {
                        var children = std.ArrayList(InlineItem).empty;
                        try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                        // Consume items covering the label `[...]`.
                        var j = i + 1;
                        while (j < old.len and itemSpan(old[j]).start < lab.after) : (j += 1) {}
                        if (itemSpan(old[j - 1]).end > lab.after) {
                            setItemSpan(&old[j - 1], .{ .start = @intCast(lab.after), .end = itemSpan(old[j - 1]).end });
                            try out.append(doc.allocator(), old[j - 1]);
                        }

                        out.shrinkRetainingCapacity(o);
                        if (is_image) {
                            try out.append(doc.allocator(), .{
                                .image = .{
                                    .span = .{ .start = open_start, .end = @intCast(lab.after) },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                        } else {
                            try out.append(doc.allocator(), .{
                                .link = .{
                                    .span = .{ .start = open_start, .end = @intCast(lab.after) },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                            max_link_opener_out = @max(max_link_opener_out, o);
                        }
                        while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                        i = j - 1;
                        continue;
                    }
                }
                // A `[` that does not resolve (or an invalid label) still
                // blocks the shortcut form: "not followed by [] or a link
                // label".
                _ = stack.pop();
                try out.append(doc.allocator(), item);
                continue;
            }

            // 3. Shortcut reference: `[text]` not followed by `[]` or a
            // link label (§6.6) — i.e. not followed by `[`. A `(` after a
            // failed inline link does not block the shortcut (§6.6 example
            // `[foo](not a link)` with `[foo]: /url1`). Applies to links
            // and images alike.
            if (close_end >= para_end or bytes[close_end] != '[') {
                if (try tryResolveReference(doc, defs, text)) |def| {
                    var children = std.ArrayList(InlineItem).empty;
                    try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                    out.shrinkRetainingCapacity(o);
                    if (is_image) {
                        try out.append(doc.allocator(), .{
                            .image = .{
                                .span = .{ .start = open_start, .end = close_end },
                                .children = children,
                                .dest = def.dest,
                                .title = def.title,
                            },
                        });
                    } else {
                        try out.append(doc.allocator(), .{
                            .link = .{
                                .span = .{ .start = open_start, .end = close_end },
                                .children = children,
                                .dest = def.dest,
                                .title = def.title,
                            },
                        });
                        max_link_opener_out = @max(max_link_opener_out, o);
                    }
                    while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                    continue;
                }
            }

            // Not a link/image: the opener can never match a later `]`.
            _ = stack.pop();
            try out.append(doc.allocator(), item);
            continue;
        }
        try out.append(doc.allocator(), item);
    }

    items.* = out; // moved; the old buffer stays in the arena
}

/// The result of scanning a reference label following a `]`.
const ScannedRefLabel = struct {
    /// Content between the label's brackets.
    content: source.Span,
    /// Position just past the label's closing `]`.
    after: usize,
};

/// Scans a reference label `[...]` starting at the `[` at position `pos`
/// (immediately after a link text's `]`). The label ends at the first `]`
/// not backslash-escaped, with no unescaped brackets inside and at least
/// one non-whitespace character (§6.6). Returns null for an invalid label.
fn scanRefLabel(bytes: []const u8, pos: usize, para_end: usize) ?ScannedRefLabel {
    if (pos >= para_end or bytes[pos] != '[') return null;
    var p = pos + 1;
    var has_nonspace = false;
    var count: usize = 0;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ']' and !isEscaped(bytes, p)) {
            if (!has_nonspace) return null;
            return .{ .content = .{ .start = @intCast(pos + 1), .end = @intCast(p) }, .after = p + 1 };
        }
        if (b == '[' and !isEscaped(bytes, p)) return null; // unescaped bracket inside
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') has_nonspace = true;
        count += 1;
        if (count > 999) return null; // §6.6: at most 999 characters
    }
    return null;
}

/// Looks up the definition matching a reference label, normalizing the
/// label for comparison. Returns null when there is no match.
fn tryResolveReference(
    doc: *document.Document,
    defs: *Definitions,
    label: source.Span,
) ParseError!?Definition {
    const key = try normalizeLabel(doc, label);
    if (defs.get(key)) |def| return def;
    return null;
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
/// §2.1 ASCII letter: `[a-zA-Z]` (the first character of a scheme).
fn isAsciiLetter(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

/// §6.8 scheme character: an ASCII letter, digit, `+`, `.`, or `-`.
fn isSchemeChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '+' or b == '.' or b == '-';
}

/// §6.8 email local-part character (the HTML5 regex's first class):
/// `[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]`.
fn isEmailLocalChar(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

/// §6.8 email domain-label character: an ASCII letter or digit, or `-`.
fn isEmailDomainChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '-';
}

/// §6.6 tag-name character: an ASCII letter, digit, or `-`.
fn isTagNameChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '-';
}

/// §6.6 attribute-name character: an ASCII letter, digit, `_`, `.`, `:`,
/// or `-` (the first character is restricted to letter/`_`/`:`).
fn isAttrNameChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '_' or b == '.' or b == ':' or b == '-';
}

/// The length of a CommonMark line ending at `i` (`\n`, `\r\n`, or `\r`),
/// or 0 when `bytes[i]` does not start one. Same definition as
/// `source.Line`.
fn lineEndingLen(bytes: []const u8, i: usize) usize {
    return switch (bytes[i]) {
        '\n' => 1,
        '\r' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1,
        else => 0,
    };
}

/// §6.8 URI autolink: `<` + scheme (2–32 chars) + `:` + content (no ASCII
/// control, space, `<`, `>`) + `>`. `pos` is at the `<`; `end` bounds the
/// scan (a line end, since content cannot contain line endings). Returns
/// null when the bytes do not form a URI autolink.
fn scanUriAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    const start = pos + 1;
    var p = start;
    // Scheme: first char an ASCII letter, then scheme chars, 2..32 total.
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    var scheme_len: usize = 1;
    p += 1;
    while (p < end and isSchemeChar(bytes[p]) and scheme_len < 32) : (p += 1) {
        scheme_len += 1;
    }
    // The scheme ends at the `:` and must be 2..32 chars (`<m:abc>` is
    // not an autolink); a 33+ char run is not a scheme.
    if (scheme_len < 2 or scheme_len > 32 or p >= end or bytes[p] != ':') return null;
    const content_start = p + 1;
    var q = content_start;
    while (q < end) : (q += 1) {
        const b = bytes[q];
        if (b == '>') {
            // The label/href is the *whole* text between the angle
            // brackets — scheme, colon, and content.
            return .{
                .span = .{ .start = @intCast(pos), .end = @intCast(q + 1) },
                .content = .{ .start = @intCast(start), .end = @intCast(q) },
                .is_email = false,
            };
        }
        // ASCII control, space, and `<` are forbidden in the content.
        if (b <= 0x20 or b == 0x7F or b == '<') return null;
    }
    return null;
}

/// §6.8 email autolink: `<` + email + `>`, where the email matches the
/// non-normative HTML5 regex (anchored). `pos` is at the `<`; `end` bounds
/// the scan. Returns null when the bytes do not form an email autolink.
fn scanEmailAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    const start = pos + 1;
    var p = start;
    // Local part: one or more local-part characters.
    if (p >= end or !isEmailLocalChar(bytes[p])) return null;
    p += 1;
    while (p < end and isEmailLocalChar(bytes[p])) : (p += 1) {}
    if (p >= end or bytes[p] != '@') return null;
    p += 1;
    // Domain: one or more dot-separated labels. Each label is
    // `[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?`: a first alphanumeric,
    // then a middle run of up to 61 alphanumerics or hyphens, then one
    // alphanumeric. The label starts and ends alphanumeric, and the whole
    // label is at most 63 chars (1 + 61 + 1). The regex is greedy, so a
    // maximal [alnum-] run after the first char is a valid label iff its
    // length is at most 62 and it ends in an alphanumeric.
    var labels: usize = 0;
    while (true) {
        if (p >= end or !isAsciiLetter(bytes[p]) and !(bytes[p] >= '0' and bytes[p] <= '9')) return null;
        p += 1;
        var run: usize = 0;
        var last_alnum = true;
        while (p < end and isEmailDomainChar(bytes[p])) : (p += 1) {
            run += 1;
            const alnum = isAsciiLetter(bytes[p]) or (bytes[p] >= '0' and bytes[p] <= '9');
            last_alnum = alnum;
            if (run > 62) return null; // middle run exceeds 61 + final char
        }
        if (!last_alnum) return null; // label must end in an alphanumeric
        labels += 1;
        if (p >= end) return null;
        if (bytes[p] == '>') {
            if (labels == 0) return null;
            return .{
                .span = .{ .start = @intCast(pos), .end = @intCast(p + 1) },
                .content = .{ .start = @intCast(start), .end = @intCast(p) },
                .is_email = true,
            };
        }
        if (bytes[p] != '.') return null;
        p += 1;
    }
}

/// Tries to recognize an autolink starting at the `<` at `pos` (§6.8): URI
/// first, then email. Returns null when neither matches (the `<` stays
/// literal text).
fn scanAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    return scanUriAutolink(bytes, pos, end) orelse scanEmailAutolink(bytes, pos, end);
}

fn scanLine(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    raw: source.Span,
    emit: source.Span,
    constructs: []const Construct,
    exclude: *u32,
) ParseError!void {
    const bytes = doc.src.bytes;
    var i = raw.start;
    var run_start = raw.start;
    var ci: usize = 0;
    // Skip constructs that closed before this line, or that an autolink
    // consumed on an earlier line (first-come: they are dead for the rest
    // of the paragraph — docs/RAW-HTML.md §2).
    while (ci < constructs.len and
        (constructs[ci].span.end <= raw.start or constructs[ci].span.start < exclude.*))
    {
        ci += 1;
    }
    while (i < raw.end) : (i += 1) {
        // Inside a construct that opened on an earlier line: skip to its
        // end; the item was appended when the construct opened.
        if (ci < constructs.len and i > constructs[ci].span.start and i < constructs[ci].span.end) {
            i = constructs[ci].span.end - 1;
            run_start = constructs[ci].span.end;
            ci += 1;
            continue;
        }
        // At a construct opening: flush the preceding text, append the
        // construct item, skip the whole construct.
        if (ci < constructs.len and i == constructs[ci].span.start) {
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            switch (constructs[ci].kind) {
                .code_span => try items.append(doc.allocator(), .{
                    .code_span = .{ .span = constructs[ci].span, .content = constructs[ci].content },
                }),
                .html_tag => try items.append(doc.allocator(), .{
                    .raw_html = .{ .span = constructs[ci].span },
                }),
            }
            i = constructs[ci].span.end - 1;
            run_start = constructs[ci].span.end;
            ci += 1;
            continue;
        }
        const b = bytes[i];
        if (b == '!' and !isEscaped(bytes, i) and
            i + 1 < raw.end and bytes[i + 1] == '[' and !isEscaped(bytes, i + 1))
        {
            // `![` with both characters unescaped is an image opener (§6.7):
            // a bracket item spanning both bytes. An escaped `!` or `[` at
            // the boundary is literal text (`\![foo]` is an escaped `!`;
            // `!\[foo]` has an escaped `[` — neither opens an image).
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            try items.append(doc.allocator(), .{
                .bracket = .{ .ch = '!', .span = .{ .start = @intCast(i), .end = @intCast(i + 2) } },
            });
            run_start = i + 2;
            i += 1; // the loop increments past the `[`
        } else if (b == '[' or b == ']') {
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
        } else if (b == '<' and !isEscaped(bytes, i)) {
            // §6.8 autolink: `<scheme:...>` or `<user@host>`. The scan is
            // per-line and the content excludes line endings, so scanning
            // within `raw` is complete; the autolink item is opaque to the
            // delimiter stack and link discovery (docs/AUTOLINKS.md §2). A
            // `(` after a failed match is literal text; an escaped `\<` is
            // literal (handled above by `!isEscaped`).
            if (scanAutolink(bytes, i, raw.end)) |al| {
                try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
                try items.append(doc.allocator(), .{ .autolink = al });
                i = al.span.end - 1; // loop increments past the `>`
                run_start = al.span.end;
                // An autolink that started before a backtick run wins the
                // first-come race: skip any construct whose opening lies
                // inside the consumed `<...>`, and record the exclusion so
                // later lines keep them dead (their closers cannot revive
                // them — docs/RAW-HTML.md §2).
                while (ci < constructs.len and constructs[ci].span.start < al.span.end) ci += 1;
                if (al.span.end > exclude.*) exclude.* = al.span.end;
            }
            // No match: fall through; the `<` is literal text.
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

/// Runs the match phase over `items` (delimiter stack, rules 1–12),
/// returning the arena-allocated match list. Mutates only
/// `front_used`/`back_used` inside delimiter items; the item list itself
/// is stable, so it is safe to alias it into a mutable slice. Each inline
/// scope is matched exactly once: paragraph/heading items, link-text
/// children, and image-description children (the latter only so the
/// consumed delimiters are known when flattening to the alt string).
fn matchItems(doc: *document.Document, items: []const InlineItem) ParseError![]const Match {
    var stack = std.ArrayList(usize).empty;
    var bottoms = Bottoms{};
    var matches = std.ArrayList(Match).empty;

    const mutable = @constCast(items);
    for (mutable, 0..) |item, i| {
        if (item != .delimiter) continue;
        try processDelimiter(doc, mutable, &stack, &bottoms, &matches, i);
    }
    return matches.items;
}

/// Matches the item list as a fresh inline scope, then materializes
/// document nodes under `block`.
fn matchInlines(doc: *document.Document, block: *document.Node, items: []const InlineItem) ParseError!void {
    try emitInlines(doc, block, @constCast(items), try matchItems(doc, items));
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
                // discoverLinksAndImages).
                const node = try doc.createNode(.link, lk.span, .{
                    .link = .{
                        .href = try resolveEscapes(doc, lk.dest),
                        .title = if (lk.title) |ts| try resolveEscapes(doc, ts) else null,
                    },
                });
                try doc.appendChild(current, node);
                try matchInlines(doc, node, lk.children.items);
            },
            .image => |im| {
                // Leaf node (no children): the description is flattened to
                // the plain-string alt at parse time, per §6.7
                // (docs/IMAGES-PARSING.md §3). `src`/`title` resolve
                // escapes like a link's href/title.
                const node = try doc.createNode(.image, im.span, .{
                    .image = .{
                        .src = try resolveEscapes(doc, im.dest),
                        .alt = try flattenAlt(doc, im.children.items),
                        .title = if (im.title) |ts| try resolveEscapes(doc, ts) else null,
                    },
                });
                try doc.appendChild(current, node);
            },
            .raw_html => |h| {
                // Leaf node: the whole tag construct, rendered verbatim
                // from the source span (no payload; docs/RAW-HTML.md §3).
                const node = try doc.createNode(.raw_html, h.span, .none);
                try doc.appendChild(current, node);
            },
            .autolink => |al| {
                // Leaf node: the raw content between `<` and `>` becomes
                // both the label (verbatim, escapes inert) and the href
                // (with `mailto:` prepended for email autolinks). The href
                // is arena-owned because of the prefix; the label is the
                // verbatim content copy (docs/AUTOLINKS.md §3).
                const content = doc.src.bytes[al.content.start..al.content.end];
                const href = if (al.is_email)
                    try std.fmt.allocPrint(doc.allocator(), "mailto:{s}", .{content})
                else
                    try doc.allocator().dupe(u8, content);
                const node = try doc.createNode(.autolink, al.span, .{
                    .autolink = .{
                        .href = href,
                        .label = try doc.allocator().dupe(u8, content),
                    },
                });
                try doc.appendChild(current, node);
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
// Inline pass: alt flattening (images, §6.7).
// ---------------------------------------------------------------------------

/// One scope frame of the alt-flattening work stack: an inline scope's
/// items plus the next item index. Emphasis matching for a scope runs when
/// the frame is pushed (it mutates delimiter items' consumed counters, so
/// the walk itself needs no match list).
const FlattenScope = struct {
    items: []const InlineItem,
    i: usize,
};

/// Flattens an image description to its plain string content (the `alt`
/// attribute), per §6.7: "only the plain string content of the image
/// description be used ... without formatting" (docs/IMAGES-PARSING.md
/// §3). Each scope (the description itself, and the text of any link or
/// nested image inside it) is first matched as a fresh inline scope
/// (delimiter stack, rules 1–12), then walked in document order: text and
/// code-span content contribute directly (escapes resolved, backticks
/// dropped), consumed delimiters contribute nothing, leftover delimiters
/// and unconsumed brackets contribute their literal bytes, soft/hard
/// breaks contribute `\n`, and link and nested-image items contribute
/// their own flattened children. Nested scopes are processed on an
/// explicit work stack, so hostile nesting cannot overflow the call
/// stack. Returns an arena-owned copy (like `code_span`/`link` payloads,
/// the alt cannot be a source slice).
fn flattenAlt(doc: *document.Document, items: []const InlineItem) ParseError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var work = std.ArrayList(FlattenScope).empty;
    defer work.deinit(doc.allocator());

    _ = try matchItems(doc, items); // consumed delimiters are known to the walk
    try work.append(doc.allocator(), .{ .items = items, .i = 0 });
    while (work.items.len > 0) {
        const top = work.items.len - 1;
        const f = &work.items[top];
        if (f.i >= f.items.len) {
            work.shrinkRetainingCapacity(top);
            continue;
        }
        const item = f.items[f.i];
        f.i += 1;
        switch (item) {
            .text => |span| try buf.appendSlice(doc.allocator(), try resolveEscapes(doc, span)),
            .code_span => |cs| try buf.appendSlice(doc.allocator(), try normalizeCodeSpan(doc, cs.content)),
            .brk => try buf.append(doc.allocator(), '\n'),
            .delimiter => |run| try buf.appendSlice(doc.allocator(), doc.src.bytes[run.span.start + run.front_used .. run.span.end - run.back_used]),
            .bracket => |br| try buf.appendSlice(doc.allocator(), doc.src.bytes[br.span.start..br.span.end]),
            .link => |lk| {
                _ = try matchItems(doc, lk.children.items);
                try work.append(doc.allocator(), .{ .items = lk.children.items, .i = 0 });
            },
            .image => |im| {
                _ = try matchItems(doc, im.children.items);
                try work.append(doc.allocator(), .{ .items = im.children.items, .i = 0 });
            },
            .autolink => |al| try buf.appendSlice(doc.allocator(), doc.src.bytes[al.content.start..al.content.end]),
            .raw_html => |h| try buf.appendSlice(doc.allocator(), doc.src.bytes[h.span.start..h.span.end]),
        }
    }
    return buf.toOwnedSlice(doc.allocator());
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

test "markdown: fenced code exposes normalized payload and exact span" {
    const oliver = @import("oliver.zig");
    const input = "  ``` zig\\+lang extra\r\n  <tag>\r x\n   ````";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const code = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.code_block, code.tag);
    try testing.expectEqual(source.Span{ .start = 0, .end = @as(u32, @intCast(input.len)) }, code.span);
    try testing.expectEqual(@as(usize, 0), code.children.items.len);
    try testing.expectEqualStrings("<tag>\nx\n", code.data.code_block.content);
    try testing.expectEqualStrings("zig+lang extra", code.data.code_block.info.?);
}

test "markdown: unclosed fences end at their containing block" {
    const oliver = @import("oliver.zig");
    const input = "> ```\n> aaa\n\nbbb\n\n- ~~~ lang\n  <x>\n  ~~~";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);

    const quote_code = root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.code_block, quote_code.tag);
    try testing.expectEqualStrings("aaa\n", quote_code.data.code_block.content);
    try testing.expectEqual(@as(?[]const u8, null), quote_code.data.code_block.info);

    try testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    const list_code = root.children.items[2].children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.code_block, list_code.tag);
    try testing.expectEqualStrings("<x>\n", list_code.data.code_block.content);
    try testing.expectEqualStrings("lang", list_code.data.code_block.info.?);
}

test "markdown: fenced blanks preserve excess list indentation without ending a blank-start item" {
    const oliver = @import("oliver.zig");
    const input = "-\n  ```\n    \n\n  more\n  ```";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const list = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    const item = list.children.items[0];
    try testing.expectEqual(@as(usize, 1), item.children.items.len);
    const code = item.children.items[0];
    try testing.expectEqual(document.Tag.code_block, code.tag);
    // Two of the four spaces belong to the list item. A wholly unindented
    // blank also remains literal content and does not make the item inert.
    try testing.expectEqualStrings("  \n\nmore\n", code.data.code_block.content);
}

test "markdown: thematic breaks precede lists and interrupt paragraphs" {
    const oliver = @import("oliver.zig");
    const input = "Foo\n***\n- item\n  * * *";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.thematic_break, root.children.items[1].tag);
    try testing.expectEqual(source.Span{ .start = 4, .end = 7 }, root.children.items[1].span);

    const list = root.children.items[2];
    try testing.expectEqual(document.Tag.list, list.tag);
    const item = list.children.items[0];
    try testing.expectEqual(@as(usize, 2), item.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, item.children.items[0].tag);
    try testing.expectEqual(document.Tag.thematic_break, item.children.items[1].tag);
    try testing.expectEqual(source.Span{ .start = 17, .end = 22 }, item.children.items[1].span);
}

test "markdown: Setext headings transform multiline paragraphs with exact spans" {
    const oliver = @import("oliver.zig");
    const input = "  Foo *bar\nbaz*  \n   ----  ";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(u8, 2), h.data.heading);
    try testing.expectEqual(source.Span{ .start = 0, .end = @as(u32, @intCast(input.len)) }, h.span);
    try testing.expectEqual(document.Tag.text, h.children.items[0].tag);
    try testing.expectEqualStrings("Foo ", h.children.items[0].data.text);
    try testing.expectEqual(document.Tag.emphasis, h.children.items[1].tag);
    const em = h.children.items[1];
    try testing.expectEqual(@as(usize, 3), em.children.items.len);
    try testing.expectEqualStrings("bar", em.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, em.children.items[1].tag);
    try testing.expectEqualStrings("baz", em.children.items[2].data.text);
}

test "markdown: Setext headings register leading definitions and preserve final backslashes" {
    const oliver = @import("oliver.zig");
    const input = "[foo]: /url\nBar\\\n===\n[foo]";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    const h = root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(u8, 1), h.data.heading);
    try testing.expectEqual(source.Span{ .start = 12, .end = 20 }, h.span);
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("Bar\\", h.children.items[0].data.text);

    const p = root.children.items[1];
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: a final paragraph backslash remains literal" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "foo\\", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqualStrings("foo\\", p.children.items[0].data.text);
}

test "markdown: a final ATX backslash remains literal" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "### foo\\", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("foo\\", h.children.items[0].data.text);
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
    // A bare run with no opener is literal text (spec example 357:
    // `*foo bar *` — note the opener is not followed by a space, so the
    // line is not a list item).
    {
        var result = try oliver.parse(testing.allocator, "*foo bar *", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("*foo bar *", p.children.items[0].data.text);
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

// --- inline images (docs/IMAGES-PARSING.md) ---

test "markdown: image structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "![foo](/uri \"title\")", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const img = p.children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    // The node span covers the whole construct: `![` .. `)`.
    try testing.expectEqual(source.Span{ .start = 0, .end = 20 }, img.span);
    try testing.expectEqualStrings("/uri", img.data.image.src);
    try testing.expectEqualStrings("foo", img.data.image.alt);
    try testing.expectEqualStrings("title", img.data.image.title.?);
    // Leaf inline: no children (the description lives in the alt string).
    try testing.expectEqual(@as(usize, 0), img.children.items.len);
}

test "markdown: image alt flattens description inlines" {
    const oliver = @import("oliver.zig");
    // Emphasis, strong, and code spans all flatten to plain string content
    // (docs/IMAGES-PARSING.md §3: "only the plain string content ...").
    {
        var result = try oliver.parse(testing.allocator, "![foo *bar*](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    {
        var result = try oliver.parse(testing.allocator, "![*a* **b** `c`](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("a b c", img.data.image.alt);
    }
    // Escapes resolve in the description.
    {
        var result = try oliver.parse(testing.allocator, "![foo \\*bar\\*](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo *bar*", img.data.image.alt);
    }
    // Escaped and unmatched brackets are literal content.
    {
        var result = try oliver.parse(testing.allocator, "![foo\\]bar](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo]bar", img.data.image.alt);
    }
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar] baz](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo [bar] baz", img.data.image.alt);
    }
    // Empty description → empty alt (spec example 581).
    {
        var result = try oliver.parse(testing.allocator, "![](/url)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("", img.data.image.alt);
    }
}

test "markdown: images may contain links and images, links may contain images" {
    const oliver = @import("oliver.zig");
    // Image description contains a link (spec example 575).
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar](/url)](/url2)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url2", img.data.image.src);
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    // Image description contains an image (spec example 574).
    {
        var result = try oliver.parse(testing.allocator, "![foo ![bar](/url)](/url2)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    // Links may contain images (spec example 540): the image is a child
    // node of the link.
    {
        var result = try oliver.parse(testing.allocator, "[![moon](moon.jpg)](/uri)", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqual(@as(usize, 1), lnk.children.items.len);
        try testing.expectEqual(document.Tag.image, lnk.children.items[0].tag);
        try testing.expectEqualStrings("moon", lnk.children.items[0].data.image.alt);
    }
    // A link inside the description does not kill the image opener, and a
    // dead `[` above a live `![` intercepts a `]` (the appendix's
    // inactive-bracket semantics; docs/IMAGES-PARSING.md §2).
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar [baz](/u)](/u2)](/u3)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("foo [bar baz](/u2)", img.data.image.alt);
    }
}

test "markdown: image openers require an unescaped bang and bracket" {
    const oliver = @import("oliver.zig");
    // Escaped `[`: literal `![foo]` (spec example 592 shape).
    {
        var result = try oliver.parse(testing.allocator, "!\\[foo]", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo]", try inlineText(&result.document, p));
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
    // Escaped `!`: literal `!` then `[foo]` (spec example 593 shape;
    // reference links are deferred, so the brackets stay literal).
    {
        var result = try oliver.parse(testing.allocator, "\\![foo]", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo]", try inlineText(&result.document, p));
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
    // A plain `!` not followed by `[` is just text.
    {
        var result = try oliver.parse(testing.allocator, "hello! world", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("hello! world", p.children.items[0].data.text);
    }
}

test "markdown: image in heading and emphasis; code spans keep it from closing" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "# ![foo](/url)", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqual(document.Tag.image, h.children.items[0].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "*![foo](/url)*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.image, em.children.items[0].tag);
    }
    // Code spans bind more tightly than brackets: the `]` inside the span
    // never closes the image, so it stays literal (`` ![foo`](/uri)` ``).
    {
        var result = try oliver.parse(testing.allocator, "![foo`](/uri)`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("![foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
        try testing.expectEqualStrings("](/uri)", p.children.items[1].data.code_span);
    }
}

test "markdown: image destination and title resolve backslash escapes" {
    const oliver = @import("oliver.zig");
    // `![x](\(foo\) \"ti\\*tle\")`: escaped parens in the destination
    // and an escaped `*` in the title, resolved into arena-owned payloads
    // exactly like a link's.
    var result = try oliver.parse(testing.allocator, "![x](\\(foo\\) \"ti\\*tle\")", .markdown, .{});
    defer result.deinit();
    const img = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("(foo)", img.data.image.src);
    try testing.expectEqualStrings("ti*tle", img.data.image.title.?);
    try testing.expectEqual(@as(usize, 0), img.children.items.len);
}

test "markdown: reference-style images resolve from definitions (full, collapsed, shortcut)" {
    const oliver = @import("oliver.zig");

    // Full: ![foo][bar] resolves through the definition table.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n\n[bar]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
        try testing.expectEqual(@as(?[]const u8, null), img.data.image.title);
        try testing.expectEqual(@as(usize, 1), countImages(&result.document));
    }

    // Collapsed: ![foo][] uses the opener's own text as the label.
    {
        var result = try oliver.parse(testing.allocator, "![foo][]\n\n[foo]: /url \"title\"\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
        try testing.expectEqualStrings("title", img.data.image.title.?);
    }

    // Shortcut: ![foo] with no trailing label.
    {
        var result = try oliver.parse(testing.allocator, "![foo]\n\n[foo]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
    }
}

test "markdown: reference-style image descriptions flatten to alt" {
    const oliver = @import("oliver.zig");

    // Emphasis drops its markers; the label matches the *raw* bracket
    // text (matching is on normalized strings, not parsed content).
    {
        var result = try oliver.parse(testing.allocator, "![*foo* bar][]\n\n[*foo* bar]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }

    // Case-insensitive labels: ![Foo][] matches [foo]:
    {
        var result = try oliver.parse(testing.allocator, "![Foo][]\n\n[foo]: /url \"title\"\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("Foo", img.data.image.alt); // alt keeps the source text
    }
}

test "markdown: reference precedence and image inline beats reference" {
    const oliver = @import("oliver.zig");

    // Inline destination wins over the reference form (appendix order).
    {
        var result = try oliver.parse(testing.allocator, "![foo](inline \"t\")\n\n[foo]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("inline", img.data.image.src);
        try testing.expectEqualStrings("t", img.data.image.title.?);
    }

    // A failed full reference is not retried as a shortcut: with both
    // [bar] and [foo] defined, ![foo][bar] is the full reference to /url;
    // the opener's own text ([foo]) is never tried.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n\n[bar]: /url\n[foo]: /url2\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
    }
}

test "markdown: reference-style image inside reference-link text" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[![foo][bar]][baz]\n\n[bar]: /img\n[baz]: /page\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/page", lnk.data.link.href);
    const img = lnk.children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("/img", img.data.image.src);
    try testing.expectEqualStrings("foo", img.data.image.alt);
}

test "markdown: unmatched reference image stays literal and shares the inactive-bracket rule" {
    const oliver = @import("oliver.zig");

    // No definition: ![foo][bar] stays literal text.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n", .markdown, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
        const para = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo][bar]", try inlineText(&result.document, para));
    }

    // A formed reference *link* inactivates earlier `[` openers, never a
    // `![`; a dead `[` still intercepts a later `]` (appendix rule).
    // `![a [b][c]]` — the inner [b][c] is a reference link, so `![a <link>`;
    // the image opener below the dead `[` cannot use that `]`.
    {
        var result = try oliver.parse(testing.allocator, "![a [b][c]]\n\n[c]: /url\n", .markdown, .{});
        defer result.deinit();
        // The image does not form: the inner link consumed the bracket.
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
}

// --- autolinks (docs/AUTOLINKS.md §6.8) ---

test "markdown: URI autolink structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "<http://foo.bar.baz>", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const a = p.children.items[0];
    try testing.expectEqual(document.Tag.autolink, a.tag);
    // The node span covers the whole `<...>` construct (20 bytes).
    try testing.expectEqual(source.Span{ .start = 0, .end = 20 }, a.span);
    // URI autolinks: href == label == the raw content, verbatim.
    try testing.expectEqualStrings("http://foo.bar.baz", a.data.autolink.href);
    try testing.expectEqualStrings("http://foo.bar.baz", a.data.autolink.label);
    // Leaf inline: no children.
    try testing.expectEqual(@as(usize, 0), a.children.items.len);
}

test "markdown: email autolinks get mailto: href" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "<foo@bar.example.com>", .markdown, .{});
        defer result.deinit();
        const a = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.autolink, a.tag);
        try testing.expectEqualStrings("mailto:foo@bar.example.com", a.data.autolink.href);
        try testing.expectEqualStrings("foo@bar.example.com", a.data.autolink.label);
    }
    // Case is preserved in both href and label (§6.8: "case-insensitive").
    {
        var result = try oliver.parse(testing.allocator, "<FOO@BAR.COM>", .markdown, .{});
        defer result.deinit();
        const a = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("mailto:FOO@BAR.COM", a.data.autolink.href);
        try testing.expectEqualStrings("FOO@BAR.COM", a.data.autolink.label);
    }
}

test "markdown: backslash escapes are inert inside autolinks" {
    const oliver = @import("oliver.zig");
    // §6.8: neither the URI nor the email may contain spaces, and
    // backslash escapes do not work inside autolinks — the content is
    // copied verbatim (unlike links, whose destination is escape-resolved).
    var result = try oliver.parse(testing.allocator, "<https://example.com/\\[\\>", .markdown, .{});
    defer result.deinit();
    const a = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.autolink, a.tag);
    try testing.expectEqualStrings("https://example.com/\\[\\", a.data.autolink.href);
    try testing.expectEqualStrings("https://example.com/\\[\\", a.data.autolink.label);
}

test "markdown: non-autolinks stay literal" {
    const oliver = @import("oliver.zig");
    // §6.8 negatives: empty, spaces, 1-char scheme, bare domain. The
    // `\\+` case stays literal text but the escape *does* resolve outside
    // autolinks (escapes only fail to work *inside* `<...>`), so its text
    // is `<foo+@bar.example.com>`.
    const inputs = [_][2][]const u8{
        .{ "<>", "<>" },
        .{ "< https://foo.bar >", "< https://foo.bar >" },
        .{ "<m:abc>", "<m:abc>" },
        .{ "<foo.bar.baz>", "<foo.bar.baz>" },
        .{ "<foo\\+@bar.example.com>", "<foo+@bar.example.com>" },
        .{ "<https://foo.bar/baz bim>", "<https://foo.bar/baz bim>" },
    };
    for (inputs) |input| {
        var result = try oliver.parse(testing.allocator, input[0], .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 0), countAutolinks(&result.document));
        // And no accidental link/image either: it stays plain text.
        try testing.expectEqualStrings(input[1], try inlineText(&result.document, p));
    }
}

test "markdown: autolinks nest inside emphasis and link text" {
    const oliver = @import("oliver.zig");
    // Emphasis around an autolink: *<http://foo.bar>*
    {
        var result = try oliver.parse(testing.allocator, "*<http://foo.bar>*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.autolink, em.children.items[0].tag);
    }
    // §6.8 precedence: the autolink swallows what looks like link syntax
    // (spec example 526) — `](uri)` is inside the autolink content. The
    // `[` before it stays literal text (no link forms), so the paragraph
    // children are [text "[", autolink].
    {
        var result = try oliver.parse(testing.allocator, "[<https://example.com/?search=](uri)>", .markdown, .{});
        defer result.deinit();
        const kids = result.document.root.children.items[0].children.items;
        try testing.expectEqual(@as(usize, 2), kids.len);
        try testing.expectEqual(document.Tag.text, kids[0].tag);
        try testing.expectEqualStrings("[", kids[0].data.text);
        const a = kids[1];
        try testing.expectEqual(document.Tag.autolink, a.tag);
        try testing.expectEqualStrings("https://example.com/?search=](uri)", a.data.autolink.href);
        try testing.expectEqual(@as(usize, 0), countLinks(&result.document));
    }
}

test "markdown: autolink in an image description flattens into alt" {
    const oliver = @import("oliver.zig");
    // The alt string is the description rendered as plain text, so the
    // autolink contributes its label (`http://x`, no `<...>`).
    var result = try oliver.parse(testing.allocator, "![<http://x>](img)", .markdown, .{});
    defer result.deinit();
    const img = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("http://x", img.data.image.alt);
}

test "markdown: raw HTML leaves preserve spans and first-come opacity" {
    const oliver = @import("oliver.zig");

    // A tag is opaque to brackets and emphasis, but its source bytes remain
    // available through the leaf span. The backtick pair inside the quoted
    // attribute must not become a code span because the tag starts first.
    const input = "*<b data=\"`x`\">[x]</b>*";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();
    const em = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.emphasis, em.tag);
    try testing.expectEqual(@as(usize, 3), em.children.items.len);
    try testing.expectEqual(document.Tag.raw_html, em.children.items[0].tag);
    try testing.expectEqual(source.Span{ .start = 1, .end = 15 }, em.children.items[0].span);
    try testing.expectEqualStrings("<b data=\"`x`\">", input[1..15]);
    try testing.expectEqual(document.Tag.text, em.children.items[1].tag);
    try testing.expectEqual(document.Tag.raw_html, em.children.items[2].tag);
    try testing.expectEqual(source.Span{ .start = 18, .end = 22 }, em.children.items[2].span);

    // Conversely, a code span that starts first keeps a tag-looking string
    // opaque and emits one code_span leaf.
    var code_result = try oliver.parse(testing.allocator, "`<b>`", .markdown, .{});
    defer code_result.deinit();
    const code_p = code_result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), code_p.children.items.len);
    try testing.expectEqual(document.Tag.code_span, code_p.children.items[0].tag);

    // A tag that starts first also wins when its attribute contains a
    // complete backtick pair.
    var tag_result = try oliver.parse(testing.allocator, "<b title=\"`x`\">", .markdown, .{});
    defer tag_result.deinit();
    const tag_p = tag_result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), tag_p.children.items.len);
    try testing.expectEqual(document.Tag.raw_html, tag_p.children.items[0].tag);
}

test "markdown: raw HTML preserves multiline bytes and flattens image alt" {
    const oliver = @import("oliver.zig");

    // The two spaces before the newline are inside the quoted attribute, so
    // this line ending is raw HTML content, not a hard break.
    {
        const input = "before <a href=\"foo  \nbar\"> after";
        var result = try oliver.parse(testing.allocator, input, .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 3), p.children.items.len);
        try testing.expectEqual(document.Tag.raw_html, p.children.items[1].tag);
        const raw = p.children.items[1];
        try testing.expectEqualStrings("<a href=\"foo  \nbar\">", input[raw.span.start..raw.span.end]);

        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>before <a href=\"foo  \nbar\"> after</p>\n", out.items);
    }

    // Raw HTML contributes its source bytes to the deliberately chosen
    // image-alt flattening policy; the image renderer then escapes them.
    {
        var result = try oliver.parse(testing.allocator, "![<b>x</b>](u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("<b>x</b>", img.data.image.alt);
    }
}

/// Counts `.autolink` nodes in a document (structural assertions).
fn countAutolinks(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .autolink) n += 1;
    }
    return n;
}

/// Counts `.link` nodes in a document (structural assertions).
fn countLinks(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .link) n += 1;
    }
    return n;
}

/// Counts `.image` nodes in a document (structural assertions).
fn countImages(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .image) n += 1;
    }
    return n;
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

test "markdown: full reference link with title" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo][bar]\n\n[bar]: /url \"title\"\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url", lnk.data.link.href);
    try testing.expectEqualStrings("title", lnk.data.link.title.?);
}

test "markdown: collapsed reference link" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo][]\n\n[foo]: /url\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url", lnk.data.link.href);
}

test "markdown: reference precedence over shortcut" {
    const oliver = @import("oliver.zig");
    // Both foo and bar defined: [foo][bar] is a full reference to bar.
    var result = try oliver.parse(testing.allocator, "[foo][bar]\n\n[foo]: /url1\n[bar]: /url2\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url2", lnk.data.link.href);
}

test "markdown: failed inline falls through to shortcut" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo](not a link)\n\n[foo]: /url1\n", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // link foo + literal text `(not a link)`.
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("foo", p.children.items[0].children.items[0].data.text);
    try testing.expectEqualStrings("(not a link)", p.children.items[1].data.text);
}

test "markdown: label normalization matches across whitespace and case" {
    const oliver = @import("oliver.zig");
    // The spec's own examples: Unicode case fold (ẞ matches SS), and
    // internal whitespace collapse ([Foo\n  bar] matches [Foo bar]).
    var r1 = try oliver.parse(testing.allocator, "[ẞ]\n\n[SS]: /url\n", .markdown, .{});
    defer r1.deinit();
    try testing.expectEqual(document.Tag.link, r1.document.root.children.items[0].children.items[0].tag);

    var r2 = try oliver.parse(testing.allocator, "[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n", .markdown, .{});
    defer r2.deinit();
    try testing.expectEqual(document.Tag.link, r2.document.root.children.items[0].children.items[0].tag);
}

test "markdown: no link when label undefined; brackets stay literal" {
    const oliver = @import("oliver.zig");
    // Shortcut with no definition, and full reference with no definition
    // for the label but one for the text (so `[foo]` is not a shortcut
    // either, being followed by a link label).
    var result = try oliver.parse(testing.allocator, "[foo][bar][baz]\n\n[baz]: /url1\n[foo]: /url2\n", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // `[foo]` literal, then a link for `[bar][baz]`.
    try testing.expectEqualStrings("[foo]", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", p.children.items[1].children.items[0].data.text);
}

test "markdown: definition-only paragraph produces no block" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo]: /url\n\nbar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqualStrings("bar", root.children.items[0].children.items[0].data.text);
}

test "markdown: shortcut reference resolves (definition after use)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo]\n\n[foo]: /url\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const p = root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: basic block quote contains its blocks, markers stripped" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    // The quote span covers the stripped content: 2 (the marker) .. end
    // of the last line's content (byte 11 = after `> bar`).
    try testing.expectEqual(@as(u32, 2), bq.span.start);
    try testing.expectEqual(@as(u32, 11), bq.span.end);
    try testing.expectEqual(@as(usize, 1), bq.children.items.len);
    const p = bq.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    // One paragraph with a soft break; the marker bytes are not in spans.
    try testing.expectEqual(@as(u32, 2), p.span.start);
    try testing.expectEqual(@as(u32, 11), p.span.end);
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", p.children.items[2].data.text);
}

test "markdown: nested block quotes" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> > foo\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    const outer = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, outer.tag);
    const inner = outer.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, inner.tag);
    const p = inner.children.items[0];
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    try testing.expectEqual(@as(u32, 4), p.span.start); // "> > " = 4 bytes
}

test "markdown: lazy continuation keeps the quote; markers stay open" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\nbar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    const p = bq.children.items[0];
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    // The lazy line's span starts at column 0 (no marker to strip).
    try testing.expectEqualStrings("bar", p.children.items[2].data.text);
    try testing.expectEqual(@as(u32, 6), p.children.items[2].span.start);
    // The quote span extends to cover the lazy line (byte 9 = after `bar`).
    try testing.expectEqual(@as(u32, 9), bq.span.end);
}

test "markdown: block quote interrupts a paragraph" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "foo\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[1].tag);
    const p = root.children.items[1].children.items[0];
    try testing.expectEqualStrings("bar", p.children.items[0].data.text);
}

test "markdown: blank line separates block quotes; marker blank keeps one" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\n\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[1].tag);

    var result2 = try oliver.parse(testing.allocator, "> foo\n>\n> bar\n", .markdown, .{});
    defer result2.deinit();
    const root2 = result2.document.root;
    try testing.expectEqual(@as(usize, 1), root2.children.items.len);
    try testing.expectEqual(@as(usize, 2), root2.children.items[0].children.items.len);
}

test "markdown: empty block quote and marker-only lines" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, ">\n>  \n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
    try testing.expectEqual(@as(usize, 0), root.children.items[0].children.items.len);
}

test "markdown: definitions inside a block quote register document-wide" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> [foo]: /url\n> [foo]\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    // The definition paragraph vanishes; the quote contains only the use.
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    try testing.expectEqual(@as(usize, 1), bq.children.items.len);
    const p = bq.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: lists merge by bullet or ordered delimiter" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "- one\n- two\n+ three\n10) ten\n20) twenty\n",
        .markdown,
        .{},
    );
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);

    const dash = root.children.items[0];
    try testing.expectEqual(document.Tag.list, dash.tag);
    try testing.expectEqual(document.ListKind.bullet, dash.data.list.kind);
    try testing.expectEqual(@as(u8, '-'), dash.data.list.bullet);
    try testing.expectEqual(@as(usize, 2), dash.children.items.len);

    const plus = root.children.items[1];
    try testing.expectEqual(document.Tag.list, plus.tag);
    try testing.expectEqual(document.ListKind.bullet, plus.data.list.kind);
    try testing.expectEqual(@as(u8, '+'), plus.data.list.bullet);

    const ordered = root.children.items[2];
    try testing.expectEqual(document.Tag.list, ordered.tag);
    try testing.expectEqual(document.ListKind.ordered, ordered.data.list.kind);
    try testing.expectEqual(@as(u8, ')'), ordered.data.list.delimiter);
    try testing.expectEqual(@as(u32, 10), ordered.data.list.start);
    try testing.expectEqual(@as(usize, 2), ordered.children.items.len);

    var separated = try oliver.parse(testing.allocator, "- a\n\n+ b\n", .markdown, .{});
    defer separated.deinit();
    try testing.expectEqual(@as(usize, 2), separated.document.root.children.items.len);
    try testing.expect(!separated.document.root.children.items[0].data.list.loose);
    try testing.expect(!separated.document.root.children.items[1].data.list.loose);
}

test "markdown: nested lists use content indentation and loose state" {
    const oliver = @import("oliver.zig");
    var nested = try oliver.parse(testing.allocator, "- parent\n  - child\n    - grandchild\n", .markdown, .{});
    defer nested.deinit();

    const outer = nested.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, outer.tag);
    try testing.expect(!outer.data.list.loose);
    const outer_item = outer.children.items[0];
    try testing.expectEqual(document.Tag.list_item, outer_item.tag);
    try testing.expectEqual(document.Tag.paragraph, outer_item.children.items[0].tag);
    const middle = outer_item.children.items[1];
    try testing.expectEqual(document.Tag.list, middle.tag);
    const middle_item = middle.children.items[0];
    const inner = middle_item.children.items[1];
    try testing.expectEqual(document.Tag.list, inner.tag);
    try testing.expectEqualStrings("grandchild", inner.children.items[0].children.items[0].children.items[0].data.text);

    var loose = try oliver.parse(testing.allocator, "- a\n- b\n\n  c\n- d\n", .markdown, .{});
    defer loose.deinit();
    const list = loose.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    try testing.expect(list.data.list.loose);
    const second = list.children.items[1];
    try testing.expectEqual(@as(usize, 2), second.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, second.children.items[0].tag);
    try testing.expectEqual(document.Tag.paragraph, second.children.items[1].tag);
}

test "markdown: blank-start and empty items stay distinct" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "-\n  first\n-\n- last\n", .markdown, .{});
    defer result.deinit();
    const list = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    try testing.expectEqual(@as(usize, 3), list.children.items.len);
    try testing.expectEqual(@as(usize, 1), list.children.items[0].children.items.len);
    try testing.expectEqual(@as(usize, 0), list.children.items[1].children.items.len);
    try testing.expectEqual(@as(usize, 1), list.children.items[2].children.items.len);
}
