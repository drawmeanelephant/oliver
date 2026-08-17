//! The stable C ABI for embedding Oliver from C, Rust, Python, Node, and
//! other FFI consumers (docs/C-ABI.md).
//!
//! Surface (include/oliver.h declares the C side):
//!
//! ```c
//! oliver_buffer oliver_render(
//!     oliver_alloc_fn alloc, oliver_free_fn free, void *ctx,
//!     const uint8_t *bytes, size_t len,
//!     int dialect, int frontmatter, uint32_t markdown_flags,
//!     int profile, int raw_html, int heading_ids, int footnotes);
//! void oliver_free(oliver_free_fn free, void *ctx, oliver_buffer buf);
//! ```
//!
//! Contract:
//! - The caller supplies the allocator: a malloc-style `alloc`/`free` pair
//!   plus an opaque context. `alloc` must provide at least `max_align_t`
//!   alignment (the malloc contract); Oliver's allocations never request
//!   more.
//! - The returned buffer is owned by the caller and must be released with
//!   `oliver_free`, passing the **same** `free` and `ctx` used at render
//!   time.
//! - Documented failures return an explicit error code in
//!   `Buffer.error_code` (`data` is null, `len` is 0, nothing to free);
//!   internal bugs abort rather than returning garbage. Input bytes are
//!   borrowed for the duration of the call only.
//!
//! The render-to-buffer path uses `std.Io.Writer.Allocating` — the Zig
//! 0.16 writer seam the session record calls out for the C ABI
//! (docs/SESSION-1-REPORT.md, architectural concern 1) — wrapped to hand
//! the caller an owned, exactly-sized buffer.

const std = @import("std");
const oliver = @import("oliver.zig");

/// Error codes returned in `Buffer.error_code`. The values are part of
/// the stable ABI; include/oliver.h mirrors them.
pub const Error = enum(c_int) {
    ok = 0,
    input_too_large = 1,
    out_of_memory = 2,
    raw_html_rejected = 3,
    raw_html_not_xml_well_formed = 4,
    invalid_argument = 5,
};

/// An owned render result. On success (`error_code == ok`), `data`
/// points to `len` bytes owned by the caller (release with
/// `oliver_free`); on any error, `data` is null and `len` is 0.
pub const Buffer = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
    error_code: c_int = @intFromEnum(Error.ok),
};

/// The C allocator shape: malloc-style, plus an opaque context.
pub const CAllocFn = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
/// The C deallocator shape: free-style, plus an opaque context.
pub const CFreeFn = *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) void;

/// Per-call state bridging the caller's C allocator pair into a Zig
/// `std.mem.Allocator` for the duration of the call. A pointer to a
/// stack-local copy is the Allocator's context; nothing escapes.
const CAllocState = struct {
    alloc_fn: CAllocFn,
    free_fn: CFreeFn,
    user_ctx: ?*anyopaque,
};

fn cAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const state: *const CAllocState = @ptrCast(@alignCast(ctx));
    // The caller's allocator must provide at least max_align_t alignment
    // (the malloc contract, documented in include/oliver.h). Oliver's
    // allocations never request more, so the pointer is usable as-is.
    std.debug.assert(alignment.toByteUnits() <= @sizeOf(std.c.max_align_t));
    const raw = state.alloc_fn(state.user_ctx, len) orelse return null;
    return @ptrCast(raw);
}

/// No in-place resize: the pair has no realloc. The Allocator wrapper
/// handles growth by allocating, copying, and freeing.
fn cResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

/// No relocation: returning null signals the wrapper to allocate, copy,
/// and free.
fn cRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn cFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const state: *const CAllocState = @ptrCast(@alignCast(ctx));
    state.free_fn(state.user_ctx, memory.ptr, memory.len);
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = cAlloc,
    .resize = cResize,
    .remap = cRemap,
    .free = cFree,
};

/// Enum values across the ABI boundary. All are validated; anything else
/// is `invalid_argument`.
const DialectC = enum(c_int) { markdown = 0, textile = 1 };
const FrontmatterC = enum(c_int) { none = 0, yaml = 1, toml = 2 };
const ProfileC = enum(c_int) { html = 0, xhtml = 1 };
const RawHtmlC = enum(c_int) { allowed = 0, escaped = 1, rejected = 2 };

/// Markdown parse-extension bitmask (parse side of
/// `oliver.MarkdownOptions`; bit 0 is the low bit).
pub const MarkdownFlag = struct {
    pub const footnotes: u32 = 1 << 0;
    pub const definition_lists: u32 = 1 << 1;
    pub const heading_attributes: u32 = 1 << 2;
    pub const strikethrough: u32 = 1 << 3;
    pub const wikilinks: u32 = 1 << 4;
    pub const callouts: u32 = 1 << 5;
    pub const smartypants: u32 = 1 << 6;
    pub const task_lists: u32 = 1 << 7;
};

/// Renders `bytes` in the given dialect into an owned buffer.
///
/// `alloc`/`free`/`ctx` are the caller's allocator pair (see the module
/// contract). `markdown_flags` is the `MarkdownFlag` bitmask; `profile`,
/// `raw_html`, `heading_ids`, and `footnotes` are the render options
/// (html.RenderOptions). `footnotes` appears on both sides: the parse
/// flag turns the extension on, the render option emits the section —
/// both are needed for footnote output.
pub export fn oliver_render(
    alloc_fn: ?CAllocFn,
    free_fn: ?CFreeFn,
    user_ctx: ?*anyopaque,
    bytes: ?[*]const u8,
    len: usize,
    dialect: c_int,
    frontmatter: c_int,
    markdown_flags: u32,
    profile: c_int,
    raw_html: c_int,
    heading_ids: c_int,
    footnotes: c_int,
) callconv(.c) Buffer {
    const alloc = alloc_fn orelse return err(Error.invalid_argument);
    const free = free_fn orelse return err(Error.invalid_argument);
    if (len > 0 and bytes == null) return err(Error.invalid_argument);
    const src = bytes orelse @as([*]const u8, @ptrFromInt(@alignOf(usize)));
    const dialect_c: DialectC = switch (dialect) {
        0 => .markdown,
        1 => .textile,
        else => return err(Error.invalid_argument),
    };
    const fm_c: FrontmatterC = switch (frontmatter) {
        0 => .none,
        1 => .yaml,
        2 => .toml,
        else => return err(Error.invalid_argument),
    };
    const profile_c: ProfileC = switch (profile) {
        0 => .html,
        1 => .xhtml,
        else => return err(Error.invalid_argument),
    };
    const raw_c: RawHtmlC = switch (raw_html) {
        0 => .allowed,
        1 => .escaped,
        2 => .rejected,
        else => return err(Error.invalid_argument),
    };
    if (heading_ids != 0 and heading_ids != 1) return err(Error.invalid_argument);
    if (footnotes != 0 and footnotes != 1) return err(Error.invalid_argument);

    var state = CAllocState{ .alloc_fn = alloc, .free_fn = free, .user_ctx = user_ctx };
    const a: std.mem.Allocator = .{ .ptr = &state, .vtable = &vtable };

    return renderImpl(
        a,
        src[0..len],
        dialect_c,
        fm_c,
        markdown_flags,
        profile_c,
        raw_c,
        heading_ids == 1,
        footnotes == 1,
    ) catch |e| err(mapError(e));
}

/// Releases a buffer returned by `oliver_render`. `free` and `ctx` must be
/// the same pair passed at render time.
pub export fn oliver_free(free_fn: ?CFreeFn, user_ctx: ?*anyopaque, buf: Buffer) callconv(.c) void {
    if (buf.data) |data| {
        if (free_fn) |free| free(user_ctx, data, buf.len);
    }
}

fn renderImpl(
    a: std.mem.Allocator,
    input: []const u8,
    dialect: DialectC,
    fm: FrontmatterC,
    markdown_flags: u32,
    profile: ProfileC,
    raw_html: RawHtmlC,
    heading_ids: bool,
    footnotes: bool,
) !Buffer {
    var result = try oliver.parse(a, input, switch (dialect) {
        .markdown => .markdown,
        .textile => .textile,
    }, .{
        .frontmatter = switch (fm) {
            .none => .none,
            .yaml => .yaml,
            .toml => .toml,
        },
        .markdown = .{
            .footnotes = markdown_flags & MarkdownFlag.footnotes != 0,
            .definition_lists = markdown_flags & MarkdownFlag.definition_lists != 0,
            .heading_attributes = markdown_flags & MarkdownFlag.heading_attributes != 0,
            .strikethrough = markdown_flags & MarkdownFlag.strikethrough != 0,
            .wikilinks = markdown_flags & MarkdownFlag.wikilinks != 0,
            .callouts = markdown_flags & MarkdownFlag.callouts != 0,
            .smartypants = markdown_flags & MarkdownFlag.smartypants != 0,
            .task_lists = markdown_flags & MarkdownFlag.task_lists != 0,
        },
    });
    defer result.deinit();

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try oliver.html.render(a, &aw.writer, &result.document, .{
        .profile = switch (profile) {
            .html => .html,
            .xhtml => .xhtml,
        },
        .raw_html = switch (raw_html) {
            .allowed => .allowed,
            .escaped => .escaped,
            .rejected => .rejected,
        },
        .heading_ids = heading_ids,
        .footnotes = footnotes,
    });

    // Move the rendered bytes into an exactly-sized allocation so the
    // caller's free (which receives the returned len) matches the
    // allocation size.
    var list = aw.toArrayList();
    defer list.deinit(a);
    const out = try a.alloc(u8, list.items.len);
    @memcpy(out, list.items);
    return .{ .data = out.ptr, .len = out.len, .error_code = @intFromEnum(Error.ok) };
}

fn err(code: Error) Buffer {
    return .{ .data = null, .len = 0, .error_code = @intFromEnum(code) };
}

fn mapError(e: anyerror) Error {
    return switch (e) {
        error.InputTooLarge => .input_too_large,
        error.OutOfMemory => .out_of_memory,
        error.RawHtmlRejected => .raw_html_rejected,
        error.RawHtmlNotXmlWellFormed => .raw_html_not_xml_well_formed,
        else => @panic("oliver_render: unhandled error"),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A malloc-style pair over an arena, so the Zig test binary exercises the
/// exact exported surface without linking libc. Arena frees are no-ops, but
/// every allocation is 16-byte aligned (the max_align_t contract).
fn testAlloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(ctx.?));
    const bytes = arena.allocator().alignedAlloc(u8, .fromByteUnits(16), size) catch return null;
    return bytes.ptr;
}

fn testFree(ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
}

fn render(
    arena: *std.heap.ArenaAllocator,
    input: []const u8,
    dialect: c_int,
    frontmatter: c_int,
    flags: u32,
    profile: c_int,
    raw_html: c_int,
    heading_ids: c_int,
    footnotes: c_int,
) Buffer {
    return oliver_render(
        testAlloc,
        testFree,
        arena,
        input.ptr,
        input.len,
        dialect,
        frontmatter,
        flags,
        profile,
        raw_html,
        heading_ids,
        footnotes,
    );
}

test "c-abi: markdown round-trips through the exported surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "# Hello *world*\n", 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
    const out = buf.data.?[0..buf.len];
    defer oliver_free(testFree, &arena, buf);
    try std.testing.expectEqualStrings("<h1>Hello <em>world</em></h1>\n", out);
}

test "c-abi: textile dialect renders through the same surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "h1. Hello *world*\n", 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
    defer oliver_free(testFree, &arena, buf);
    try std.testing.expectEqualStrings("<h1>Hello <strong>world</strong></h1>\n", buf.data.?[0..buf.len]);
}

test "c-abi: markdown extension flags enable the extension surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // footnotes (bit 0) + wikilinks (bit 4) + callouts (bit 5) +
    // smartypants (bit 6) + task lists (bit 7); footnotes render on.
    const flags = MarkdownFlag.footnotes | MarkdownFlag.wikilinks | MarkdownFlag.callouts | MarkdownFlag.smartypants | MarkdownFlag.task_lists;
    const buf = render(&arena, "- [x] done [[Page|label]] \"hi\"\n\n> [!note] Title\n> Body\n\n[^a]: def\n\nref[^a]\n", 0, 0, flags, 0, 0, 0, 1);
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
    defer oliver_free(testFree, &arena, buf);
    const out = buf.data.?[0..buf.len];
    try std.testing.expect(std.mem.indexOf(u8, out, "<input type=\"checkbox\" disabled=\"\" checked=\"\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "callout callout-note") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{201c}hi\u{201d}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "footnotes") != null);
}

test "c-abi: raw_html rejected returns the explicit error code, not a panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "before <script>bad()</script> after\n", 0, 0, 0, 0, 2, 0, 0);
    try std.testing.expectEqual(@as(c_int, 3), buf.error_code);
    try std.testing.expect(buf.data == null);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "c-abi: xhtml fails closed on raw html with the well-formedness code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "<div>\nraw\n</div>\n", 0, 0, 0, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 4), buf.error_code);
    try std.testing.expect(buf.data == null);
}

test "c-abi: raw_html escaped renders well-formed under both profiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "before <script>bad()</script> after\n", 0, 0, 0, 1, 1, 0, 0);
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
    defer oliver_free(testFree, &arena, buf);
    try std.testing.expectEqualStrings("<p>before &lt;script&gt;bad()&lt;/script&gt; after</p>\n", buf.data.?[0..buf.len]);
}

test "c-abi: invalid arguments return invalid_argument instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "# x\n";

    // null allocator pair
    const b1 = oliver_render(null, testFree, &arena, input.ptr, input.len, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b1.error_code);
    const b2 = oliver_render(testAlloc, null, &arena, input.ptr, input.len, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b2.error_code);

    // null bytes with nonzero length
    const b3 = oliver_render(testAlloc, testFree, &arena, null, 4, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b3.error_code);

    // out-of-range enum values
    const b4 = render(&arena, input, 9, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b4.error_code);
    const b5 = render(&arena, input, 0, 9, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b5.error_code);
    const b6 = render(&arena, input, 0, 0, 0, 9, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b6.error_code);
    const b7 = render(&arena, input, 0, 0, 0, 0, 9, 0, 0);
    try std.testing.expectEqual(@as(c_int, 5), b7.error_code);
    const b8 = render(&arena, input, 0, 0, 0, 0, 0, 2, 0);
    try std.testing.expectEqual(@as(c_int, 5), b8.error_code);
    const b9 = render(&arena, input, 0, 0, 0, 0, 0, 0, 2);
    try std.testing.expectEqual(@as(c_int, 5), b9.error_code);
}

test "c-abi: oliver_free releases the buffer through the same allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const buf = render(&arena, "# x\n", 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
    oliver_free(testFree, &arena, buf); // no-op under the arena; the contract is exercised
    try std.testing.expectEqual(@as(c_int, 0), buf.error_code);
}
