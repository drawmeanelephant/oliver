//! CommonMark 0.31.2 classified expectations.
//!
//! Each example in the official spec is classified as:
//! - `supported`: Oliver's output matches the normative HTML.
//! - `not_yet`: Oliver is known not to match yet; an unexpected pass fails the
//!   gate (it must be reviewed and moved to `supported`).
//! - `divergence`: Oliver deliberately differs; the exact output is pinned
//!   in `divergences` below.
//!
//! The official corpus is bound by byte count, example count, and SHA-256 in
//! `spec_conformance.zig`; see docs/COMMONMARK-EXPECTATIONS.md.

pub const spec_version = "0.31.2";
pub const spec_url = "https://spec.commonmark.org/0.31.2/spec.txt";
pub const spec_sha256_hex = "bfef4ddc97276b6ab6c2a28ace48478e35b1c50e60cde9f517ab8ab030aa3b82";
pub const spec_byte_count: usize = 204_857;
/// Normative examples in the official 0.31.2 spec.txt.
pub const example_count: usize = 652;

pub const Class = enum { supported, not_yet, divergence };

pub const Range = struct {
    first: usize,
    last: usize,
    class: Class,
};

/// Reviewed partition as of the entity/HTML-blocks-types-6/7 milestone
/// (636 supported / 16 not-yet / 0 divergences), committed as a plain,
/// diffable partition. Keep ranges sorted, adjacent, and nonoverlapping.
pub const ranges = [_]Range{
    // Tabs (1-11) through backslash escapes (12-24), entity references
    // (25-41). Example 21 (`<a href="/bar\/)">`) is an HTML block type 7;
    // the entity examples 25-27 and 31-34 decode references in text, link
    // destinations/titles, and fenced info strings, and 37-41 keep
    // nonentities literal while decoding real ones.
    .{ .first = 1, .last = 41, .class = .supported },
    // Precedence/thematic breaks (42-61), ATX (62-79), Setext (80-106),
    // indented (107-118) and fenced (119-147) code.
    .{ .first = 42, .last = 147, .class = .supported },
    // HTML blocks (148-191): types 6 and 7 conform (block-tag lines and
    // whole-line tags, ending at a blank line); types 1-5 (script/pre/
    // style/textarea element blocks, comments, PIs, declarations, CDATA —
    // 169-173 and 176-183) need the cross-line matching-terminator
    // machinery and remain not-yet.
    .{ .first = 148, .last = 168, .class = .supported },
    .{ .first = 169, .last = 173, .class = .not_yet },
    .{ .first = 174, .last = 175, .class = .supported },
    .{ .first = 176, .last = 183, .class = .not_yet },
    .{ .first = 184, .last = 191, .class = .supported },
    // Link reference definitions (192-218) through paragraphs (219-226).
    .{ .first = 192, .last = 200, .class = .supported },
    // Example 201: `[foo]: <bar>(baz)` — an angle destination followed by
    // `(` is not a definition. Not yet.
    .{ .first = 201, .last = 201, .class = .not_yet },
    .{ .first = 202, .last = 307, .class = .supported },
    // Lists (301-326): 308 and 309 interleave `<!-- -->` (a type-2 HTML
    // block) with list items; they conform only once types 1-5 land.
    .{ .first = 308, .last = 309, .class = .not_yet },
    .{ .first = 310, .last = 652, .class = .supported },
};

pub const Divergence = struct {
    example: usize,
    name: []const u8,
    rationale: []const u8,
    actual: []const u8,
};

pub const divergences = [_]Divergence{};

/// No named divergences remain: the recorded ATX trailing-backslash choice
/// (old divergence example 646) was resolved to the normative output by the
/// thematic-break/Setext milestone. A future deliberate divergence must add
/// a record here with its rationale and exact pinned Oliver output.
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
