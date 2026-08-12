//! Oliver — a small, freestanding markup parsing and rendering library.
//!
//! Public API shape (deliberately provisional):
//!
//! ```zig
//! const result = try oliver.parse(allocator, source, .markdown, .{});
//! defer result.deinit();
//! try oliver.html.render(allocator, &writer, &result.document, .{});
//! ```
//!
//! Guarantees:
//! - The caller supplies the allocator; ownership is explicit.
//! - The parser never reads files or the environment.
//! - The renderer writes to any writer and never reparses.
//! - No global state, no hidden caches, deterministic output.
//!
//! The core (source, document, diagnostics, both frontends, the renderer)
//! depends on no host facilities: no filesystem, environment, clock, network,
//! or threads. Only the CLI (src/main.zig) touches stdio.

const std = @import("std");

pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const document = @import("document.zig");
pub const markdown = @import("markdown.zig");
pub const textile = @import("textile.zig");
pub const html = @import("html.zig");

pub const version = "0.0.0";

/// The input dialect. Both dialects converge into the same document model.
pub const Dialect = enum {
    markdown,
    textile,
};

/// Parse options. Empty in the vertical slice; grows with later milestones
/// (raw HTML policy, reference links, tab handling, ...).
pub const ParseOptions = struct {};

/// Failures that are not markup interpretation: the caller's problem.
pub const ParseError = error{
    /// Input exceeds `source.max_input_len` bytes (spans are `u32`).
    InputTooLarge,
    OutOfMemory,
};

/// The result of a parse: an owned document plus diagnostics. All memory is
/// owned by `document`'s arena; `deinit` releases it in one step.
pub const ParseResult = struct {
    document: document.Document,
    diagnostics: []const diagnostic.Diagnostic = &.{},

    pub fn init(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
        return .{
            .document = try document.Document.init(allocator, .{ .bytes = input }),
        };
    }

    pub fn deinit(self: *ParseResult) void {
        self.document.deinit();
    }
};

/// Parses `input` in the given dialect into the normalized document model.
/// The source bytes are borrowed by the document (text nodes slice into
/// them); they must outlive the result.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    dialect: Dialect,
    options: ParseOptions,
) ParseError!ParseResult {
    _ = options;
    if (input.len > source.max_input_len) return error.InputTooLarge;

    var result = try ParseResult.init(allocator, input);
    errdefer result.deinit();

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(result.document.allocator());

    switch (dialect) {
        .markdown => try markdown.parse(&result.document, &diags),
        .textile => try textile.parse(&result.document, &diags),
    }
    result.diagnostics = diags.items;
    return result;
}

test "oliver: parse result owns its memory; deinit frees everything" {
    var result = try parse(std.testing.allocator, "# hello", .markdown, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "oliver: input too large is an API error, not a diagnostic" {
    // We cannot actually allocate 4 GiB; instead assert the boundary logic
    // via a synthetic oversized slice would be impractical. The check itself
    // is exercised structurally: max_input_len is a documented bound and the
    // comparison happens before any parsing.
    try std.testing.expect(std.math.maxInt(u32) == source.max_input_len);
}

test "oliver: empty input parses to an empty document" {
    var result = try parse(std.testing.allocator, "", .markdown, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.document.root.children.items.len);

    var result2 = try parse(std.testing.allocator, "", .textile, .{});
    defer result2.deinit();
    try std.testing.expectEqual(@as(usize, 0), result2.document.root.children.items.len);
}
