//! Reviewed expectations for the canonical CommonMark 0.31.2 `spec.txt`.
//!
//! Every official example number belongs to exactly one adjacent range below:
//! - `supported`: Oliver must match the normative HTML byte-for-byte.
//! - `not_yet`: Oliver is known not to match yet; an unexpected pass fails the
//!   classified gate so the manifest cannot silently become stale.
//! - `divergence`: Oliver deliberately differs. The named record also pins the
//!   current Oliver HTML, so either conformance or a different failure requires
//!   an explicit review.

pub const spec_version = "0.31.2";
pub const spec_url = "https://spec.commonmark.org/0.31.2/spec.txt";
pub const spec_sha256_hex = "bfef4ddc97276b6ab6c2a28ace48478e35b1c50e60cde9f517ab8ab030aa3b82";
pub const spec_byte_count: usize = 204_857;
pub const example_count: usize = 652;

pub const Class = enum { supported, not_yet, divergence };

pub const Range = struct {
    first: usize,
    last: usize,
    class: Class,
};

/// Generated once from the reviewed cb9ea53 scorecard, then committed as a
/// plain, diffable partition. Keep ranges sorted, adjacent, and nonoverlapping.
pub const ranges = [_]Range{
    // Tabs (examples 1-11).
    .{ .first = 1, .last = 9, .class = .not_yet },
    .{ .first = 10, .last = 10, .class = .supported },
    .{ .first = 11, .last = 11, .class = .not_yet },
    // Backslash escapes (12-24).
    .{ .first = 12, .last = 17, .class = .supported },
    .{ .first = 18, .last = 19, .class = .not_yet },
    .{ .first = 20, .last = 20, .class = .supported },
    .{ .first = 21, .last = 21, .class = .not_yet },
    .{ .first = 22, .last = 23, .class = .supported },
    .{ .first = 24, .last = 24, .class = .not_yet },
    // Entity references (25-41).
    .{ .first = 25, .last = 27, .class = .not_yet },
    .{ .first = 28, .last = 30, .class = .supported },
    .{ .first = 31, .last = 34, .class = .not_yet },
    .{ .first = 35, .last = 35, .class = .supported },
    .{ .first = 36, .last = 41, .class = .not_yet },
    // Block/inline precedence (42) and thematic breaks (43-61).
    .{ .first = 42, .last = 42, .class = .supported },
    .{ .first = 43, .last = 43, .class = .not_yet },
    .{ .first = 44, .last = 46, .class = .supported },
    .{ .first = 47, .last = 48, .class = .not_yet },
    .{ .first = 49, .last = 49, .class = .supported },
    .{ .first = 50, .last = 54, .class = .not_yet },
    .{ .first = 55, .last = 56, .class = .supported },
    .{ .first = 57, .last = 61, .class = .not_yet },
    // ATX headings (62-79).
    .{ .first = 62, .last = 68, .class = .supported },
    .{ .first = 69, .last = 69, .class = .not_yet },
    .{ .first = 70, .last = 76, .class = .supported },
    .{ .first = 77, .last = 77, .class = .not_yet },
    .{ .first = 78, .last = 79, .class = .supported },
    // Setext headings (80-106).
    .{ .first = 80, .last = 86, .class = .not_yet },
    .{ .first = 87, .last = 87, .class = .supported },
    .{ .first = 88, .last = 92, .class = .not_yet },
    .{ .first = 93, .last = 93, .class = .supported },
    .{ .first = 94, .last = 96, .class = .not_yet },
    .{ .first = 97, .last = 97, .class = .supported },
    .{ .first = 98, .last = 105, .class = .not_yet },
    .{ .first = 106, .last = 106, .class = .supported },
    // Indented code blocks (107-118).
    .{ .first = 107, .last = 107, .class = .not_yet },
    .{ .first = 108, .last = 109, .class = .supported },
    .{ .first = 110, .last = 112, .class = .not_yet },
    .{ .first = 113, .last = 113, .class = .supported },
    .{ .first = 114, .last = 118, .class = .not_yet },
    // Fenced code blocks (119-147).
    .{ .first = 119, .last = 120, .class = .not_yet },
    .{ .first = 121, .last = 121, .class = .supported },
    .{ .first = 122, .last = 137, .class = .not_yet },
    .{ .first = 138, .last = 138, .class = .supported },
    .{ .first = 139, .last = 144, .class = .not_yet },
    .{ .first = 145, .last = 145, .class = .supported },
    .{ .first = 146, .last = 147, .class = .not_yet },
    // HTML blocks (148-191).
    .{ .first = 148, .last = 167, .class = .not_yet },
    .{ .first = 168, .last = 168, .class = .supported },
    .{ .first = 169, .last = 186, .class = .not_yet },
    .{ .first = 187, .last = 187, .class = .supported },
    .{ .first = 188, .last = 191, .class = .not_yet },
    // Link reference definitions (192-218).
    .{ .first = 192, .last = 200, .class = .supported },
    .{ .first = 201, .last = 201, .class = .not_yet },
    .{ .first = 202, .last = 210, .class = .supported },
    .{ .first = 211, .last = 212, .class = .not_yet },
    .{ .first = 213, .last = 214, .class = .supported },
    .{ .first = 215, .last = 215, .class = .not_yet },
    .{ .first = 216, .last = 218, .class = .supported },
    // Paragraphs (219-226).
    .{ .first = 219, .last = 224, .class = .supported },
    .{ .first = 225, .last = 225, .class = .not_yet },
    .{ .first = 226, .last = 226, .class = .supported },
    // Blank lines (227).
    .{ .first = 227, .last = 227, .class = .supported },
    // Block quotes (228-252).
    .{ .first = 228, .last = 230, .class = .supported },
    .{ .first = 231, .last = 231, .class = .not_yet },
    .{ .first = 232, .last = 233, .class = .supported },
    .{ .first = 234, .last = 234, .class = .not_yet },
    .{ .first = 235, .last = 235, .class = .supported },
    .{ .first = 236, .last = 237, .class = .not_yet },
    .{ .first = 238, .last = 245, .class = .supported },
    .{ .first = 246, .last = 246, .class = .not_yet },
    .{ .first = 247, .last = 251, .class = .supported },
    .{ .first = 252, .last = 252, .class = .not_yet },
    // List items (253-300).
    .{ .first = 253, .last = 254, .class = .not_yet },
    .{ .first = 255, .last = 256, .class = .supported },
    .{ .first = 257, .last = 257, .class = .not_yet },
    .{ .first = 258, .last = 262, .class = .supported },
    .{ .first = 263, .last = 264, .class = .not_yet },
    .{ .first = 265, .last = 269, .class = .supported },
    .{ .first = 270, .last = 274, .class = .not_yet },
    .{ .first = 275, .last = 277, .class = .supported },
    .{ .first = 278, .last = 278, .class = .not_yet },
    .{ .first = 279, .last = 285, .class = .supported },
    .{ .first = 286, .last = 290, .class = .not_yet },
    .{ .first = 291, .last = 299, .class = .supported },
    .{ .first = 300, .last = 300, .class = .not_yet },
    // Lists (301-326).
    .{ .first = 301, .last = 307, .class = .supported },
    .{ .first = 308, .last = 309, .class = .not_yet },
    .{ .first = 310, .last = 312, .class = .supported },
    .{ .first = 313, .last = 313, .class = .not_yet },
    .{ .first = 314, .last = 317, .class = .supported },
    .{ .first = 318, .last = 318, .class = .not_yet },
    .{ .first = 319, .last = 320, .class = .supported },
    .{ .first = 321, .last = 321, .class = .not_yet },
    .{ .first = 322, .last = 323, .class = .supported },
    .{ .first = 324, .last = 324, .class = .not_yet },
    .{ .first = 325, .last = 326, .class = .supported },
    // Inlines preamble example (327).
    .{ .first = 327, .last = 327, .class = .supported },
    // Code spans (328-349).
    .{ .first = 328, .last = 349, .class = .supported },
    // Emphasis and strong emphasis (350-481).
    .{ .first = 350, .last = 481, .class = .supported },
    // Links (482-571).
    .{ .first = 482, .last = 502, .class = .supported },
    .{ .first = 503, .last = 503, .class = .not_yet },
    .{ .first = 504, .last = 505, .class = .supported },
    .{ .first = 506, .last = 506, .class = .not_yet },
    .{ .first = 507, .last = 571, .class = .supported },
    // Images (572-593).
    .{ .first = 572, .last = 593, .class = .supported },
    // Autolinks (594-612).
    .{ .first = 594, .last = 612, .class = .supported },
    // Raw HTML (613-632).
    .{ .first = 613, .last = 632, .class = .supported },
    // Hard line breaks (633-647).
    .{ .first = 633, .last = 643, .class = .supported },
    .{ .first = 644, .last = 644, .class = .not_yet },
    .{ .first = 645, .last = 645, .class = .supported },
    .{ .first = 646, .last = 646, .class = .divergence },
    .{ .first = 647, .last = 647, .class = .supported },
    // Soft line breaks (648-649).
    .{ .first = 648, .last = 649, .class = .supported },
    // Textual content (650-652).
    .{ .first = 650, .last = 652, .class = .supported },
};

pub const Divergence = struct {
    example: usize,
    name: []const u8,
    rationale: []const u8,
    actual: []const u8,
};

pub const divergences = [_]Divergence{
    .{
        .example = 646,
        .name = "ATX trailing backslash is a hard break",
        .rationale = "docs/FEATURE-MATRIX.md recorded ambiguity 10",
        .actual = "<h3>foo<br />\n</h3>\n",
    },
};

pub fn classFor(number: usize) ?Class {
    // There are few ranges and this runs once per example; a simple binary
    // search keeps lookup predictable without introducing a generated table.
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (number < range.first) {
            hi = mid;
        } else if (number > range.last) {
            lo = mid + 1;
        } else {
            return range.class;
        }
    }
    return null;
}

pub fn divergenceFor(number: usize) ?Divergence {
    for (divergences) |divergence| {
        if (divergence.example == number) return divergence;
    }
    return null;
}
