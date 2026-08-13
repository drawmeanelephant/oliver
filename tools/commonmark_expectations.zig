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

/// Reviewed partition after the tab-stop and indented-code milestone
/// (592 supported / 60 not-yet / 0 divergences), committed as a plain,
/// diffable partition. Keep ranges sorted, adjacent, and nonoverlapping.
pub const ranges = [_]Range{
    // Tabs (examples 1-11).
    .{ .first = 1, .last = 17, .class = .supported },
    // Backslash escapes (12-24).
    .{ .first = 18, .last = 20, .class = .supported },
    .{ .first = 21, .last = 21, .class = .not_yet },
    .{ .first = 22, .last = 24, .class = .supported },
    // Entity references (25-41).
    .{ .first = 25, .last = 27, .class = .not_yet },
    .{ .first = 28, .last = 30, .class = .supported },
    .{ .first = 31, .last = 34, .class = .not_yet },
    .{ .first = 35, .last = 35, .class = .supported },
    .{ .first = 36, .last = 36, .class = .supported },
    .{ .first = 37, .last = 41, .class = .not_yet },
    // Block/inline precedence (42) and thematic breaks (43-61).
    .{ .first = 42, .last = 68, .class = .supported },
    // ATX headings (62-79).
    .{ .first = 69, .last = 84, .class = .supported },
    // Setext headings (80-106).
    .{ .first = 85, .last = 106, .class = .supported },
    // Indented code blocks (107-118).
    .{ .first = 107, .last = 118, .class = .supported },
    // Fenced code blocks (119-147).
    .{ .first = 119, .last = 147, .class = .supported },
    // HTML blocks (148-191).
    .{ .first = 148, .last = 167, .class = .not_yet },
    .{ .first = 168, .last = 168, .class = .supported },
    .{ .first = 169, .last = 186, .class = .not_yet },
    .{ .first = 187, .last = 187, .class = .supported },
    .{ .first = 188, .last = 191, .class = .not_yet },
    // Link reference definitions (192-218).
    .{ .first = 192, .last = 200, .class = .supported },
    .{ .first = 201, .last = 201, .class = .not_yet },
    .{ .first = 202, .last = 224, .class = .supported },
    // Paragraphs (219-226).
    .{ .first = 225, .last = 230, .class = .supported },
    // Block quotes (228-252).
    .{ .first = 231, .last = 252, .class = .supported },
    // List items (253-300).
    .{ .first = 253, .last = 307, .class = .supported },
    // Lists (301-326).
    .{ .first = 308, .last = 309, .class = .not_yet },
    .{ .first = 310, .last = 502, .class = .supported },
    // Links (482-571).
    .{ .first = 503, .last = 503, .class = .not_yet },
    .{ .first = 504, .last = 505, .class = .supported },
    .{ .first = 506, .last = 506, .class = .not_yet },
    .{ .first = 507, .last = 652, .class = .supported },
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
