//! The normalized typed document model.
//!
//! Both dialects parse into this representation; the HTML renderer consumes
//! only this representation. See docs/DOCUMENT-MODEL.md for the design.
//!
//! Ownership: a `Document` owns an arena. All nodes are allocated from that
//! arena, and text payloads are slices *into the source bytes* (borrowed, not
//! copied). `Document.deinit` releases the arena in one step.
//!
//! Invariants:
//! - The root node is always a `.document` whose children are blocks.
//! - Block tags contain block or inline children as documented per tag;
//!   `thematic_break`, `code_block`, and `html_block` are childless leaves;
//!   `table` children are `table_row` blocks, `table_row` children are
//!   `table_cell` blocks, and `table_cell` children are inlines (a cell
//!   behaves like a paragraph: inline content only, no blocks).
//! - `emphasis`/`strong`/`bold`/`italic`/`deleted`/`inserted`/
//!   `superscript`/`subscript`/`span`/`link` contain inline children; the
//!   leaf inline tags (`text`, `code_span`, `image`, `autolink`, `raw_html`,
//!   `soft_break`, `hard_break`) never have children.
//! - `list` children are `list_item` blocks; `list_item` children are blocks.
//! - `Node.data.text` always points into the document's source bytes;
//!   `raw_html` reads its bytes by `Node.span` and carries no data payload;
//!   `data.code_span`, `data.code_block` (content/info), `data.html_block`,
//!   `data.image` (src/alt/title),
//!   `data.autolink` (href/label), and
//!   `data.link` (href/title) are the arena-owned (copied) payloads
//!   (see docs/DOCUMENT-MODEL.md invariant 9).

const std = @import("std");
const source = @import("source.zig");

/// Node kinds. Blocks and inlines are distinguished (see `Tag.isBlock`).
/// This set is deliberately small; see docs/DOCUMENT-MODEL.md for the
/// planned growth path.
pub const Tag = enum {
    /// Root of every document. Children: blocks.
    document,
    /// Paragraph. Children: inlines.
    paragraph,
    /// Heading. Children: inlines. `data.heading` is the level 1..6.
    heading,
    /// A thematic break (Markdown §4.1). Leaf block with no children or
    /// payload; renderers choose their own horizontal-rule serialization.
    thematic_break,
    /// A fenced or indented code block. Leaf block with no children;
    /// `data.code_block` holds normalized content and optional info string.
    code_block,
    /// A raw HTML block (Markdown §4.6). Leaf block with no children;
    /// `data.html_block` holds the verbatim container-stripped source lines
    /// (arena-owned — container prefixes make the block's source
    /// non-contiguous).
    html_block,
    /// A block quote (Markdown `>` markers, §5.1). Container: children are
    /// blocks. Span covers its lines' content with markers stripped.
    block_quote,
    /// A list (Markdown §5.3). Container: children are list items.
    /// `data.list` carries the type, ordered start, and tight/loose flag.
    /// Span covers its items' content lines.
    list,
    /// A list item (Markdown §5.2). Container: children are blocks.
    /// Span covers its content lines (marker stripped).
    list_item,
    /// A table (GFM §4.10 extension, Markdown frontend only). Container:
    /// children are `table_row` blocks — the first is the header row, the
    /// rest are body rows. `data.table` holds the per-column alignment.
    /// Span covers the header line through the last row line.
    table,
    /// One row of a `table` (GFM §4.10). Container: children are
    /// `table_cell` blocks. No payload: the row's role (header vs body)
    /// is its position under the table, and each cell carries its own
    /// header/alignment flags.
    table_row,
    /// One cell of a `table_row` (GFM §4.10). Container: children are
    /// inlines. `data.table_cell` carries the header flag and the column
    /// alignment (resolved at parse time so the renderer never indexes
    /// across nodes).
    table_cell,
    /// Plain text. `data.text` is a slice of the source.
    text,
    /// Emphasized inline content (Markdown `*x*`, `_x_`; Textile `_x_`).
    /// Children: inlines.
    emphasis,
    /// Strongly emphasized inline content (Markdown `**x**`, `__x__`; Textile
    /// `*x*`). Children: inlines.
    strong,
    /// Bold inline content (Textile `**x**`). Children: inlines. Textile
    /// distinguishes bold `**x**` → `<b>` from strong `*x*` → `<strong>`;
    /// Markdown has no bold tag.
    bold,
    /// Italic inline content (Textile `__x__`). Children: inlines. Textile
    /// distinguishes italic `__x__` → `<i>` from emphasis `_x_` → `<em>`;
    /// Markdown has no italic tag.
    italic,
    /// Deleted inline content (Textile `-x-`). Children: inlines.
    deleted,
    /// Inserted inline content (Textile `+x+`). Children: inlines.
    inserted,
    /// Superscript inline content (Textile `^x^`). Children: inlines.
    superscript,
    /// Subscript inline content (Textile `~x~`). Children: inlines.
    subscript,
    /// A generic inline span (Textile `%x%`). Children: inlines. No payload:
    /// attribute-bearing forms (`%{style}x%` etc.) are a later milestone.
    span,
    /// Inline code (Markdown backtick span; Textile `@x@`). No
    /// children; `data.code_span` is the normalized content, one of the text
    /// payloads owned by the document arena rather than borrowed from the
    /// source (newlines become spaces, so it cannot be a source slice).
    code_span,
    /// An inline link (Markdown `[text](dest "title")`; Textile `"text":
    /// url` planned). Children: inlines (the link text). `data.link` holds
    /// the arena-owned, escape-resolved href and optional title.
    link,
    /// An inline image (Markdown `![alt](src "title")`; Textile
    /// `!url(alt)!` planned). Leaf: no children. `data.image` holds the
    /// arena-owned src, the flattened plain-string alt, and the optional
    /// title (docs/IMAGES-PARSING.md §3: the description's inlines are
    /// flattened to a string at parse time; the image node carries no
    /// subtree).
    image,
    /// An autolink (Markdown `<scheme:...>` or `<user@host>`, §6.5). Leaf:
    /// no children. `data.autolink` holds the arena-owned href (the raw
    /// URI, or `mailto:` + the email) and the label (the raw content
    /// verbatim — backslash escapes are inert inside autolinks, so unlike
    /// `data.link` this payload is *not* escape-resolved;
    /// docs/AUTOLINKS.md §3).
    autolink,
    /// A raw HTML tag (Markdown §6.6): an open/closing tag, comment,
    /// processing instruction, declaration, or CDATA section. Leaf: no
    /// children. No data payload — the renderer writes the source bytes
    /// of `node.span` verbatim, without escaping (docs/RAW-HTML.md §3).
    raw_html,
    /// A line break that renders as a newline in HTML (Markdown soft break).
    soft_break,
    /// A line break that renders as `<br />` in HTML (Markdown hard break,
    /// Textile line break).
    hard_break,

    pub fn isBlock(self: Tag) bool {
        return switch (self) {
            .document, .paragraph, .heading, .thematic_break, .code_block, .html_block, .block_quote, .list, .list_item, .table, .table_row, .table_cell => true,
            .text, .emphasis, .strong, .bold, .italic, .deleted, .inserted, .superscript, .subscript, .span, .code_span, .link, .image, .autolink, .raw_html, .soft_break, .hard_break => false,
        };
    }

    pub fn isInline(self: Tag) bool {
        return switch (self) {
            .text, .emphasis, .strong, .bold, .italic, .deleted, .inserted, .superscript, .subscript, .span, .code_span, .link, .image, .autolink, .raw_html, .soft_break, .hard_break => true,
            .document, .paragraph, .heading, .thematic_break, .code_block, .html_block, .block_quote, .list, .list_item, .table, .table_row, .table_cell => false,
        };
    }
};

/// Per-tag payload. Only the field matching the tag is meaningful.
pub const Data = union(enum) {
    none,
    /// `.paragraph`: the Textile block attributes (`p(...).`/`p{...}.`
    /// signatures), empty for plain paragraphs. Markdown paragraphs carry
    /// none.
    paragraph: Paragraph,
    /// `.block_quote`: the Textile block attributes (`bq(...).`/`bq{...}.`
    /// signatures), empty for plain quotes. Markdown quotes carry none.
    block_quote: BlockQuote,
    /// `.heading`: level, 1..6, plus the Textile block attributes
    /// (`hN(...).`/`hN{...}.` signatures); Markdown headings carry none.
    heading: Heading,
    /// `.text`: borrowed slice of the document source.
    text: []const u8,
    /// `.code_span`: normalized content. Arena-owned copy (not a source
    /// slice) because line endings are converted to spaces; see the
    /// ownership note in the module comment and docs/DOCUMENT-MODEL.md.
    code_span: []const u8,
    /// `.code_block`: normalized literal content and optional trimmed,
    /// escape-resolved info string. Both are arena-owned because content
    /// line endings/indentation and info-string escapes (and entity
    /// references, §2.5) are normalized.
    code_block: CodeBlock,
    /// `.html_block`: the verbatim container-stripped source lines of the
    /// block. Arena-owned because container prefixes are stripped (the
    /// lines are not contiguous in the source).
    html_block: []const u8,
    /// `.link`: escape-resolved destination and optional title, both
    /// arena-owned copies (backslash escapes do not survive as source
    /// slices). The title is null when absent, not an empty string.
    link: Link,
    /// `.image`: escape-resolved src and optional title (like `link`),
    /// plus the flattened plain-string alt. All arena-owned copies; the
    /// alt is the description's inlines flattened per §6.4 (see
    /// docs/IMAGES-PARSING.md §3), so it cannot be a source slice. The
    /// title is null when absent, not an empty string.
    image: Image,
    /// `.autolink`: the href and label, both arena-owned copies of the
    /// raw autolink content. Unlike `link`, backslash escapes are inert
    /// inside autolinks (§6.5), so the content is copied verbatim — never
    /// passed through escape resolution (docs/AUTOLINKS.md §3).
    autolink: Autolink,
    /// `.list`: the list's type, its bullet character or ordered delimiter,
    /// the ordered start number (1 for bullet lists; the first item's number
    /// for ordered), and the tight/loose flag (docs/BLOCKS-PARSING.md §4:
    /// loose iff any item pair is separated by a blank line or any item
    /// directly contains two blocks separated by one).
    list: List,
    /// `.table`: the per-column alignment, in order, one entry per column
    /// (GFM §4.10: from the delimiter row; Textile: from the header row),
    /// plus optional Textile table attributes.
    table: Table,
    /// `.table_row`: the row's optional Textile attributes.
    table_row: TableRow,
    /// `.table_cell`: the header flag, the column alignment (GFM), the
    /// Textile colspan/rowspan, and the cell's Textile attributes,
    /// resolved at parse time so the renderer never indexes across nodes.
    table_cell: TableCell,
};

/// The payload of a `.paragraph` node: the Textile block attributes in the
/// fixed render order (style/class/id/lang; docs/TEXTILE-PARITY.md §8).
pub const Paragraph = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.block_quote` node: the Textile block attributes.
pub const BlockQuote = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.heading` node: the level (1..6) and the Textile
/// block attributes.
pub const Heading = struct {
    level: u8,
    attrs: []const Attribute = &.{},
};

/// The payload of a `.code_block` leaf. `content` uses `\n` line endings and
/// includes one newline for every source content line. `info` is the complete
/// trimmed, escape-resolved fence info string, or null when absent; renderers
/// may interpret it. `escape` selects the Textile `pre.` verbatim form (no
/// escaping, no `<code>` wrapper); Markdown and Textile `bc.` keep the
/// default. `attrs` are the Textile block-attribute modifiers (`bc{...}.`),
/// emitted on the `<pre>` element; Markdown carries none.
pub const CodeBlock = struct {
    content: []const u8,
    /// The complete trimmed, escape-resolved fence info string, or null when
    /// absent; renderers may interpret it.
    info: ?[]const u8 = null,
    /// Textile `pre.` renders the content verbatim inside `<pre>`; when
    /// true (Markdown fenced/indented and Textile `bc.`) the content is
    /// escaped inside `<pre><code>`.
    escape: bool = true,
    /// Textile block-attribute modifiers, emitted on the `<pre>` element.
    attrs: []const Attribute = &.{},
};

/// `.autolink` payload: the raw content between `<` and `>`, verbatim
/// (escapes inert), plus the href it expands to. For a URI autolink the
/// href is the content itself; for an email autolink it is `mailto:` +
/// the content. Both are arena-owned copies (the `mailto:` prefix cannot
/// be a source slice).
pub const Autolink = struct {
    href: []const u8,
    label: []const u8,
};

/// The payload of a `.list` node (Markdown §5.3). `bullet`/`delimiter`
/// are what define "same type" for merging adjacent items: same bullet
/// character, or same ordered delimiter (`.` vs `)`).
pub const ListKind = enum { bullet, ordered };

pub const List = struct {
    /// Bullet or ordered.
    kind: ListKind,
    /// For `.bullet`: the marker character (`-`, `+`, or `*`).
    bullet: u8 = 0,
    /// For `.ordered`: the delimiter (`.` or `)`).
    delimiter: u8 = 0,
    /// For `.ordered`: the start number (its first item's number).
    /// Always 1 for bullet lists.
    start: u32 = 1,
    /// Tight (false) vs loose (true). Paragraphs directly in a tight
    /// list's items render without `<p>`.
    loose: bool = false,
};

/// Column alignment of a GFM table (§4.10), from the delimiter row:
/// `---` unaligned, `:---` left, `---:` right, `:---:` center. `none`
/// renders without an `align` attribute. `justify` is the Textile `<>`
/// modifier (full justification); GFM never produces it, and Textile
/// renders its alignment through CSS styles rather than the `align`
/// attribute, so it only appears in table-level metadata.
pub const TableAlign = enum {
    none,
    left,
    center,
    right,
    justify,
};

/// One cell/row/table attribute (Textile): a fixed-name/value pair in the
/// documented render order `style`, `class`, `id`, `lang`. The `style`
/// value is the complete composed style string (user rule + padding +
/// text-align + vertical-align, joined with `; `); all values are
/// arena-owned copies (Textile normalizes them, so they cannot borrow the
/// source). GFM tables carry no attributes.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// The payload of a `.table` node: the per-column alignment, one entry
/// per column, in column order (GFM §4.10: from the delimiter row; Textile
/// tables: from the header row, the source of the column-default
/// propagation rule). The column count is `alignment.len`; GFM body rows
/// pad or truncate their cells to it. `attrs` holds Textile table
/// attributes (`table{...}.`/`table(...).` signatures). `sections` selects
/// the HTML structure: GFM tables render with `<thead>`/`<tbody>` sections
/// (row 0 is the header row), while Textile tables render as flat `<tr>`
/// rows — the Textile references show no thead/tbody even with header
/// cells (docs/TEXTILE-PARITY.md §7).
pub const Table = struct {
    alignment: []const TableAlign,
    attrs: []const Attribute = &.{},
    sections: bool = false,
};

/// The payload of a `.table_row` node: the Textile row attributes
/// (`{style}`, `(class)`, `(#id)`, `[lang]`, padding, `^`/`~` valign — all
/// composed into the row's `style` where applicable). GFM rows carry no
/// attributes.
pub const TableRow = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.table_cell` node: `header` selects `<th>` vs
/// `<td>`, `alignment` selects the optional `align` attribute (GFM),
/// `colspan`/`rowspan` (Textile `\n`/`/n` modifiers, 1 when absent), and
/// `attrs` holds the Textile cell attributes (`{style}`, `(class)`,
/// `(#id)`, `[lang]`, padding, and the `<`/`>`/`=`/`<>`/`^`/`~` alignment
/// modifiers — all resolved at parse time into the cell's `style`). All
/// are resolved at parse time from the row's position and the table's
/// column alignment, so rendering needs no cross-node lookup.
pub const TableCell = struct {
    header: bool,
    alignment: TableAlign,
    colspan: u8 = 1,
    rowspan: u8 = 1,
    attrs: []const Attribute = &.{},
};

/// The payload of a `.image` node: the resolved src, the flattened
/// plain-string alt (always present, possibly empty — the spec's `alt=""`
/// for `![](/url)`), and the optional title. `src` and `title` are
/// escape-resolved like `link.href`/`link.title`; percent-encoding of the
/// src is a renderer policy shared with href (docs/ARCHITECTURE.md). The
/// alt is the plain string content of the image description (no
/// formatting) and is HTML-escaped at render like text.
pub const Image = struct {
    src: []const u8,
    alt: []const u8,
    title: ?[]const u8,
};

/// The payload of a `.link` node: the resolved href and optional title.
/// Both are arena-owned copies of source ranges with backslash escapes
/// applied (§6.3: "with backslash-escapes in effect as described above").
/// Percent-encoding of the href is a renderer policy (spec: "Renderers may
/// make different decisions about how to escape or normalize URLs"), so the
/// model stores the plain resolved URI.
pub const Link = struct {
    href: []const u8,
    title: ?[]const u8,
};

pub const Node = struct {
    tag: Tag,
    span: source.Span,
    data: Data = .none,
    children: std.ArrayList(*Node) = .empty,

    pub fn isBlock(self: *const Node) bool {
        return self.tag.isBlock();
    }

    pub fn isInline(self: *const Node) bool {
        return self.tag.isInline();
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// Borrowed input; text payloads slice into it.
    src: source.Source,
    root: *Node,

    pub fn init(backing: std.mem.Allocator, src: source.Source) !Document {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Node);
        root.* = .{
            .tag = .document,
            .span = .{ .start = 0, .end = @intCast(src.bytes.len) },
        };
        return .{ .arena = arena, .src = src, .root = root };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Allocator for this document's arena; the only allocator nodes use.
    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Creates a node owned by the document's arena.
    pub fn createNode(
        self: *Document,
        tag: Tag,
        span: source.Span,
        data: Data,
    ) !*Node {
        const node = try self.arena.allocator().create(Node);
        node.* = .{ .tag = tag, .span = span, .data = data };
        return node;
    }

    pub fn appendChild(self: *Document, parent: *Node, child: *Node) !void {
        try parent.children.append(self.arena.allocator(), child);
    }

    /// Source bytes covered by a span.
    pub fn text(self: *const Document, span: source.Span) []const u8 {
        return self.src.bytes[span.start..span.end];
    }

    /// Pre-order (document order) traversal. Deterministic: a parent is
    /// yielded before its children, and children are yielded in append order.
    /// Uses an explicit stack, so traversal depth does not consume the call
    /// stack — important for untrusted, deeply nested documents.
    pub const Iterator = struct {
        arena: std.mem.Allocator,
        stack: std.ArrayList(*Node) = .empty,

        pub fn init(arena: std.mem.Allocator, root: *Node) !Iterator {
            var self = Iterator{ .arena = arena };
            try self.stack.append(arena, root);
            return self;
        }

        pub fn next(self: *Iterator) !?*Node {
            const node = self.stack.pop() orelse return null;
            var i = node.children.items.len;
            while (i > 0) {
                i -= 1;
                try self.stack.append(self.arena, node.children.items[i]);
            }
            return node;
        }

        pub fn deinit(self: *Iterator) void {
            self.stack.deinit(self.arena);
        }
    };
};

test "document: creation, spans, deterministic pre-order traversal" {
    const src = source.Source{ .bytes = "# hi" };
    var doc = try Document.init(std.testing.allocator, src);
    defer doc.deinit();

    const h = try doc.createNode(.heading, .{ .start = 0, .end = 4 }, .{ .heading = .{ .level = 1 } });
    const t = try doc.createNode(.text, .{ .start = 2, .end = 4 }, .{ .text = "hi" });
    try doc.appendChild(h, t);
    try doc.appendChild(doc.root, h);

    var it = try Document.Iterator.init(std.testing.allocator, doc.root);
    defer it.deinit();
    try std.testing.expectEqual(Tag.document, (try it.next()).?.tag);
    try std.testing.expectEqual(Tag.heading, (try it.next()).?.tag);
    try std.testing.expectEqual(Tag.text, (try it.next()).?.tag);
    try std.testing.expectEqual(@as(?*Node, null), try it.next());
}

test "document: text payloads borrow the source" {
    const src = source.Source{ .bytes = "hello world" };
    var doc = try Document.init(std.testing.allocator, src);
    defer doc.deinit();
    const t = try doc.createNode(.text, .{ .start = 6, .end = 11 }, .{ .text = doc.text(.{ .start = 6, .end = 11 }) });
    try std.testing.expectEqualStrings("world", t.data.text);
    // The payload aliases the source slice rather than copying it.
    try std.testing.expect(t.data.text.ptr == src.bytes.ptr + 6);
}
