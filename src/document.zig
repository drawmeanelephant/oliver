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
//! - Block tags contain block or inline children as documented per tag.
//! - `emphasis`/`strong`/`link` contain inline children; the leaf inline
//!   tags (`text`, `code_span`, `image`, `autolink`, `soft_break`,
//!   `hard_break`) never have children.
//! - `Node.data.text` always points into the document's source bytes;
//!   `data.code_span`, `data.image` (src/alt/title),
//!   `data.autolink` (href/label), and
//!   `data.link` (href/title) are the arena-owned (copied) payloads
//!   (see docs/DOCUMENT-MODEL.md invariant 5).

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
    /// A block quote (Markdown `>` markers, §5.1). Container: children are
    /// blocks. Span covers its lines' content with markers stripped.
    block_quote,
    /// Plain text. `data.text` is a slice of the source.
    text,
    /// Emphasized inline content (Markdown `*x*`, `_x_`). Children: inlines.
    emphasis,
    /// Strongly emphasized inline content (Markdown `**x**`, `__x__`).
    /// Children: inlines.
    strong,
    /// Inline code (Markdown backtick span; Textile `@x@` planned). No
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
    /// An autolink (Markdown `<scheme:...>` or `<user@host>`, §6.8). Leaf:
    /// no children. `data.autolink` holds the arena-owned href (the raw
    /// URI, or `mailto:` + the email) and the label (the raw content
    /// verbatim — backslash escapes are inert inside autolinks, so unlike
    /// `data.link` this payload is *not* escape-resolved;
    /// docs/AUTOLINKS.md §3).
    autolink,
    /// A line break that renders as a newline in HTML (Markdown soft break).
    soft_break,
    /// A line break that renders as `<br />` in HTML (Markdown hard break,
    /// Textile line break).
    hard_break,

    pub fn isBlock(self: Tag) bool {
        return switch (self) {
            .document, .paragraph, .heading, .block_quote => true,
            .text, .emphasis, .strong, .code_span, .link, .image, .autolink, .soft_break, .hard_break => false,
        };
    }

    pub fn isInline(self: Tag) bool {
        return switch (self) {
            .text, .emphasis, .strong, .code_span, .link, .image, .autolink, .soft_break, .hard_break => true,
            .document, .paragraph, .heading, .block_quote => false,
        };
    }
};

/// Per-tag payload. Only the field matching the tag is meaningful.
pub const Data = union(enum) {
    none,
    /// `.heading`: level, 1..6.
    heading: u8,
    /// `.text`: borrowed slice of the document source.
    text: []const u8,
    /// `.code_span`: normalized content. Arena-owned copy (not a source
    /// slice) because line endings are converted to spaces; see the
    /// ownership note in the module comment and docs/DOCUMENT-MODEL.md.
    code_span: []const u8,
    /// `.link`: escape-resolved destination and optional title, both
    /// arena-owned copies (backslash escapes do not survive as source
    /// slices). The title is null when absent, not an empty string.
    link: Link,
    /// `.image`: escape-resolved src and optional title (like `link`),
    /// plus the flattened plain-string alt. All arena-owned copies; the
    /// alt is the description's inlines flattened per §6.7 (see
    /// docs/IMAGES-PARSING.md §3), so it cannot be a source slice. The
    /// title is null when absent, not an empty string.
    image: Image,
    /// `.autolink`: the href and label, both arena-owned copies of the
    /// raw autolink content. Unlike `link`, backslash escapes are inert
    /// inside autolinks (§6.8), so the content is copied verbatim — never
    /// passed through escape resolution (docs/AUTOLINKS.md §3).
    autolink: Autolink,
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
/// applied (§6.6: "with backslash-escapes in effect as described above").
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

    const h = try doc.createNode(.heading, .{ .start = 0, .end = 4 }, .{ .heading = 1 });
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
