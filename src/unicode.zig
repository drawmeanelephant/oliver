//! Unicode character classification used by the inline parser.
//!
//! Implements the two character classes the CommonMark spec (§2.1) defines
//! for delimiter flanking:
//!
//! - Unicode whitespace: a character in the Unicode Zs general category, or a
//!   tab (U+0009), line feed (U+000A), form feed (U+000C), or carriage return
//!   (U+000D). Note the spec deliberately excludes U+000B (vertical tab).
//! - Unicode punctuation: a character in the Unicode P (punctuation) or S
//!   (symbol) general categories.
//!
//! The tables below are generated from the Unicode Character Database (via
//! Python's `unicodedata`, Unicode 13.0.0) by `tools/gen-unicode.py` — a
//! Unicode-standard data source, not any parser implementation. Ranges are
//! sorted, non-overlapping, inclusive `[start, end]` pairs flattened into a
//! `u21` array; classification is binary search.
//!
//! Malformed UTF-8 is classified as neither whitespace nor punctuation
//! (i.e., ordinary text), matching Oliver's policy of degrading hostile input
//! to text rather than failing.

const std = @import("std");

/// Whitespace: Zs category plus tab, line feed, form feed, carriage return.
/// 9 ranges, 21 code points.
const whitespace_ranges = [_]u21{
    0x9,    0xA,    0xC,    0xD,    0x20,   0x20,   0xA0,   0xA0,
    0x1680, 0x1680, 0x2000, 0x200A, 0x202F, 0x202F, 0x205F, 0x205F,
    0x3000, 0x3000,
};

/// Punctuation: Unicode P (punctuation) and S (symbol) general categories.
/// 331 ranges, 8362 code points.
const punctuation_ranges = [_]u21{
    0x21,    0x2F,    0x3A,    0x40,    0x5B,    0x60,    0x7B,    0x7E,
    0xA1,    0xA9,    0xAB,    0xAC,    0xAE,    0xB1,    0xB4,    0xB4,
    0xB6,    0xB8,    0xBB,    0xBB,    0xBF,    0xBF,    0xD7,    0xD7,
    0xF7,    0xF7,    0x2C2,   0x2C5,   0x2D2,   0x2DF,   0x2E5,   0x2EB,
    0x2ED,   0x2ED,   0x2EF,   0x2FF,   0x375,   0x375,   0x37E,   0x37E,
    0x384,   0x385,   0x387,   0x387,   0x3F6,   0x3F6,   0x482,   0x482,
    0x55A,   0x55F,   0x589,   0x58A,   0x58D,   0x58F,   0x5BE,   0x5BE,
    0x5C0,   0x5C0,   0x5C3,   0x5C3,   0x5C6,   0x5C6,   0x5F3,   0x5F4,
    0x606,   0x60F,   0x61B,   0x61B,   0x61E,   0x61F,   0x66A,   0x66D,
    0x6D4,   0x6D4,   0x6DE,   0x6DE,   0x6E9,   0x6E9,   0x6FD,   0x6FE,
    0x700,   0x70D,   0x7F6,   0x7F9,   0x7FE,   0x7FF,   0x830,   0x83E,
    0x85E,   0x85E,   0x964,   0x965,   0x970,   0x970,   0x9F2,   0x9F3,
    0x9FA,   0x9FB,   0x9FD,   0x9FD,   0xA76,   0xA76,   0xAF0,   0xAF1,
    0xB70,   0xB70,   0xBF3,   0xBFA,   0xC77,   0xC77,   0xC7F,   0xC7F,
    0xC84,   0xC84,   0xD4F,   0xD4F,   0xD79,   0xD79,   0xDF4,   0xDF4,
    0xE3F,   0xE3F,   0xE4F,   0xE4F,   0xE5A,   0xE5B,   0xF01,   0xF17,
    0xF1A,   0xF1F,   0xF34,   0xF34,   0xF36,   0xF36,   0xF38,   0xF38,
    0xF3A,   0xF3D,   0xF85,   0xF85,   0xFBE,   0xFC5,   0xFC7,   0xFCC,
    0xFCE,   0xFDA,   0x104A,  0x104F,  0x109E,  0x109F,  0x10FB,  0x10FB,
    0x1360,  0x1368,  0x1390,  0x1399,  0x1400,  0x1400,  0x166D,  0x166E,
    0x169B,  0x169C,  0x16EB,  0x16ED,  0x1735,  0x1736,  0x17D4,  0x17D6,
    0x17D8,  0x17DB,  0x1800,  0x180A,  0x1940,  0x1940,  0x1944,  0x1945,
    0x19DE,  0x19FF,  0x1A1E,  0x1A1F,  0x1AA0,  0x1AA6,  0x1AA8,  0x1AAD,
    0x1B5A,  0x1B6A,  0x1B74,  0x1B7C,  0x1BFC,  0x1BFF,  0x1C3B,  0x1C3F,
    0x1C7E,  0x1C7F,  0x1CC0,  0x1CC7,  0x1CD3,  0x1CD3,  0x1FBD,  0x1FBD,
    0x1FBF,  0x1FC1,  0x1FCD,  0x1FCF,  0x1FDD,  0x1FDF,  0x1FED,  0x1FEF,
    0x1FFD,  0x1FFE,  0x2010,  0x2027,  0x2030,  0x205E,  0x207A,  0x207E,
    0x208A,  0x208E,  0x20A0,  0x20BF,  0x2100,  0x2101,  0x2103,  0x2106,
    0x2108,  0x2109,  0x2114,  0x2114,  0x2116,  0x2118,  0x211E,  0x2123,
    0x2125,  0x2125,  0x2127,  0x2127,  0x2129,  0x2129,  0x212E,  0x212E,
    0x213A,  0x213B,  0x2140,  0x2144,  0x214A,  0x214D,  0x214F,  0x214F,
    0x218A,  0x218B,  0x2190,  0x2426,  0x2440,  0x244A,  0x249C,  0x24E9,
    0x2500,  0x2775,  0x2794,  0x2B73,  0x2B76,  0x2B95,  0x2B97,  0x2BFF,
    0x2CE5,  0x2CEA,  0x2CF9,  0x2CFC,  0x2CFE,  0x2CFF,  0x2D70,  0x2D70,
    0x2E00,  0x2E2E,  0x2E30,  0x2E52,  0x2E80,  0x2E99,  0x2E9B,  0x2EF3,
    0x2F00,  0x2FD5,  0x2FF0,  0x2FFB,  0x3001,  0x3004,  0x3008,  0x3020,
    0x3030,  0x3030,  0x3036,  0x3037,  0x303D,  0x303F,  0x309B,  0x309C,
    0x30A0,  0x30A0,  0x30FB,  0x30FB,  0x3190,  0x3191,  0x3196,  0x319F,
    0x31C0,  0x31E3,  0x3200,  0x321E,  0x322A,  0x3247,  0x3250,  0x3250,
    0x3260,  0x327F,  0x328A,  0x32B0,  0x32C0,  0x33FF,  0x4DC0,  0x4DFF,
    0xA490,  0xA4C6,  0xA4FE,  0xA4FF,  0xA60D,  0xA60F,  0xA673,  0xA673,
    0xA67E,  0xA67E,  0xA6F2,  0xA6F7,  0xA700,  0xA716,  0xA720,  0xA721,
    0xA789,  0xA78A,  0xA828,  0xA82B,  0xA836,  0xA839,  0xA874,  0xA877,
    0xA8CE,  0xA8CF,  0xA8F8,  0xA8FA,  0xA8FC,  0xA8FC,  0xA92E,  0xA92F,
    0xA95F,  0xA95F,  0xA9C1,  0xA9CD,  0xA9DE,  0xA9DF,  0xAA5C,  0xAA5F,
    0xAA77,  0xAA79,  0xAADE,  0xAADF,  0xAAF0,  0xAAF1,  0xAB5B,  0xAB5B,
    0xAB6A,  0xAB6B,  0xABEB,  0xABEB,  0xFB29,  0xFB29,  0xFBB2,  0xFBC1,
    0xFD3E,  0xFD3F,  0xFDFC,  0xFDFD,  0xFE10,  0xFE19,  0xFE30,  0xFE52,
    0xFE54,  0xFE66,  0xFE68,  0xFE6B,  0xFF01,  0xFF0F,  0xFF1A,  0xFF20,
    0xFF3B,  0xFF40,  0xFF5B,  0xFF65,  0xFFE0,  0xFFE6,  0xFFE8,  0xFFEE,
    0xFFFC,  0xFFFD,  0x10100, 0x10102, 0x10137, 0x1013F, 0x10179, 0x10189,
    0x1018C, 0x1018E, 0x10190, 0x1019C, 0x101A0, 0x101A0, 0x101D0, 0x101FC,
    0x1039F, 0x1039F, 0x103D0, 0x103D0, 0x1056F, 0x1056F, 0x10857, 0x10857,
    0x10877, 0x10878, 0x1091F, 0x1091F, 0x1093F, 0x1093F, 0x10A50, 0x10A58,
    0x10A7F, 0x10A7F, 0x10AC8, 0x10AC8, 0x10AF0, 0x10AF6, 0x10B39, 0x10B3F,
    0x10B99, 0x10B9C, 0x10EAD, 0x10EAD, 0x10F55, 0x10F59, 0x11047, 0x1104D,
    0x110BB, 0x110BC, 0x110BE, 0x110C1, 0x11140, 0x11143, 0x11174, 0x11175,
    0x111C5, 0x111C8, 0x111CD, 0x111CD, 0x111DB, 0x111DB, 0x111DD, 0x111DF,
    0x11238, 0x1123D, 0x112A9, 0x112A9, 0x1144B, 0x1144F, 0x1145A, 0x1145B,
    0x1145D, 0x1145D, 0x114C6, 0x114C6, 0x115C1, 0x115D7, 0x11641, 0x11643,
    0x11660, 0x1166C, 0x1173C, 0x1173F, 0x1183B, 0x1183B, 0x11944, 0x11946,
    0x119E2, 0x119E2, 0x11A3F, 0x11A46, 0x11A9A, 0x11A9C, 0x11A9E, 0x11AA2,
    0x11C41, 0x11C45, 0x11C70, 0x11C71, 0x11EF7, 0x11EF8, 0x11FD5, 0x11FF1,
    0x11FFF, 0x11FFF, 0x12470, 0x12474, 0x16A6E, 0x16A6F, 0x16AF5, 0x16AF5,
    0x16B37, 0x16B3F, 0x16B44, 0x16B45, 0x16E97, 0x16E9A, 0x16FE2, 0x16FE2,
    0x1BC9C, 0x1BC9C, 0x1BC9F, 0x1BC9F, 0x1D000, 0x1D0F5, 0x1D100, 0x1D126,
    0x1D129, 0x1D164, 0x1D16A, 0x1D16C, 0x1D183, 0x1D184, 0x1D18C, 0x1D1A9,
    0x1D1AE, 0x1D1E8, 0x1D200, 0x1D241, 0x1D245, 0x1D245, 0x1D300, 0x1D356,
    0x1D6C1, 0x1D6C1, 0x1D6DB, 0x1D6DB, 0x1D6FB, 0x1D6FB, 0x1D715, 0x1D715,
    0x1D735, 0x1D735, 0x1D74F, 0x1D74F, 0x1D76F, 0x1D76F, 0x1D789, 0x1D789,
    0x1D7A9, 0x1D7A9, 0x1D7C3, 0x1D7C3, 0x1D800, 0x1D9FF, 0x1DA37, 0x1DA3A,
    0x1DA6D, 0x1DA74, 0x1DA76, 0x1DA83, 0x1DA85, 0x1DA8B, 0x1E14F, 0x1E14F,
    0x1E2FF, 0x1E2FF, 0x1E95E, 0x1E95F, 0x1ECAC, 0x1ECAC, 0x1ECB0, 0x1ECB0,
    0x1ED2E, 0x1ED2E, 0x1EEF0, 0x1EEF1, 0x1F000, 0x1F02B, 0x1F030, 0x1F093,
    0x1F0A0, 0x1F0AE, 0x1F0B1, 0x1F0BF, 0x1F0C1, 0x1F0CF, 0x1F0D1, 0x1F0F5,
    0x1F10D, 0x1F1AD, 0x1F1E6, 0x1F202, 0x1F210, 0x1F23B, 0x1F240, 0x1F248,
    0x1F250, 0x1F251, 0x1F260, 0x1F265, 0x1F300, 0x1F6D7, 0x1F6E0, 0x1F6EC,
    0x1F6F0, 0x1F6FC, 0x1F700, 0x1F773, 0x1F780, 0x1F7D8, 0x1F7E0, 0x1F7EB,
    0x1F800, 0x1F80B, 0x1F810, 0x1F847, 0x1F850, 0x1F859, 0x1F860, 0x1F887,
    0x1F890, 0x1F8AD, 0x1F8B0, 0x1F8B1, 0x1F900, 0x1F978, 0x1F97A, 0x1F9CB,
    0x1F9CD, 0x1FA53, 0x1FA60, 0x1FA6D, 0x1FA70, 0x1FA74, 0x1FA78, 0x1FA7A,
    0x1FA80, 0x1FA86, 0x1FA90, 0x1FAA8, 0x1FAB0, 0x1FAB6, 0x1FAC0, 0x1FAC2,
    0x1FAD0, 0x1FAD6, 0x1FB00, 0x1FB92, 0x1FB94, 0x1FBCA,
};

fn inRanges(cp: u21, ranges: []const u21) bool {
    // Find the last range whose start is <= cp, then test its end.
    var lo: usize = 0;
    var hi: usize = ranges.len / 2;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid * 2] <= cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo == 0) return false;
    return ranges[(lo - 1) * 2 + 1] >= cp;
}

/// True if `cp` is Unicode whitespace (spec §2.1: Zs, or tab/LF/FF/CR).
pub fn isWhitespace(cp: u21) bool {
    return inRanges(cp, &whitespace_ranges);
}

/// True if `cp` is Unicode punctuation (spec §2.1: P or S categories).
pub fn isPunctuation(cp: u21) bool {
    return inRanges(cp, &punctuation_ranges);
}

fn isContinuation(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Decodes the code point starting at byte offset `i`, or null on invalid
/// UTF-8 or end of input. A valid ASCII byte is always its own code point.
///
/// This is a strict, hand-rolled decoder (never panics): overlong encodings
/// and surrogate code points are rejected, sequences must not run past the
/// end of input, and every continuation byte is validated. Malformed bytes
/// degrade to `null`, which the delimiter classifier treats as
/// non-whitespace non-punctuation (docs/INLINE-PARSING.md §6).
pub fn decode(bytes: []const u8, i: usize) ?u21 {
    if (i >= bytes.len) return null;
    const b0 = bytes[i];
    if (b0 < 0x80) return b0;
    const len: usize = switch (b0) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return null, // continuation byte, C0/C1, or 0xF5+
    };
    if (i + len > bytes.len) return null;
    const b1 = bytes[i + 1];
    if (!isContinuation(b1)) return null;
    // Second-byte constraints: reject overlong encodings (E0/F0) and
    // surrogate code points (ED) / code points above U+10FFFF (F4).
    switch (b0) {
        0xE0 => if (b1 < 0xA0) return null,
        0xED => if (b1 > 0x9F) return null,
        0xF0 => if (b1 < 0x90) return null,
        0xF4 => if (b1 > 0x8F) return null,
        else => {},
    }
    var cp: u21 = switch (len) {
        2 => b0 & 0x1F,
        3 => b0 & 0x0F,
        4 => b0 & 0x07,
        else => unreachable,
    };
    cp = (cp << 6) | (b1 & 0x3F);
    for (2..len) |k| {
        const b = bytes[i + k];
        if (!isContinuation(b)) return null;
        cp = (cp << 6) | (b & 0x3F);
    }
    return cp;
}

/// Decodes the code point that ends just before byte offset `i` (the last
/// character of `bytes[0..i]`), or null if none or if the bytes there are
/// not a valid UTF-8 sequence. Safe when `i` is mid-character for malformed
/// input (returns null).
pub fn decodePrev(bytes: []const u8, i: usize) ?u21 {
    if (i == 0) return null;
    // Walk back over continuation bytes to the lead byte (or a lone
    // non-continuation byte).
    var start = i - 1;
    while (start > 0 and isContinuation(bytes[start])) start -= 1;
    const window = bytes[start..i];
    const b0 = window[0];
    if (b0 < 0x80) return if (window.len == 1) b0 else null;
    const len: usize = switch (b0) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return null,
    };
    // The sequence must be exactly the window: not truncated, not extended
    // by continuation bytes of a following character.
    if (window.len != len) return null;
    return decode(bytes, start);
}

const testing = std.testing;

test "unicode: whitespace and punctuation classification" {
    // Whitespace: ASCII space, tab, CR, LF, and the Zs set.
    try testing.expect(isWhitespace(' '));
    try testing.expect(isWhitespace('\t'));
    try testing.expect(isWhitespace('\n'));
    try testing.expect(isWhitespace('\r'));
    try testing.expect(isWhitespace('\x0C')); // form feed
    try testing.expect(!isWhitespace('\x0B')); // vertical tab is NOT whitespace per spec
    try testing.expect(isWhitespace(0xA0)); // NBSP
    try testing.expect(isWhitespace(0x2007)); // figure space (Zs)
    try testing.expect(isWhitespace(0x3000)); // ideographic space
    try testing.expect(!isWhitespace('a'));
    try testing.expect(!isWhitespace(0x2028)); // line separator (Zl), not Zs

    // Punctuation: ASCII and non-ASCII P/S categories.
    try testing.expect(isPunctuation('!'));
    try testing.expect(isPunctuation('*'));
    try testing.expect(isPunctuation('"'));
    try testing.expect(isPunctuation('.'));
    try testing.expect(isPunctuation(0x3001)); // full-width comma (Po)
    try testing.expect(isPunctuation(0x3002)); // full-width period
    try testing.expect(isPunctuation(0x20AC)); // euro sign (Sc, symbol)
    try testing.expect(isPunctuation(0x2190)); // leftwards arrow (So, symbol)
    try testing.expect(isPunctuation(0x30FB)); // katakana middle dot
    try testing.expect(!isPunctuation('a'));
    try testing.expect(!isPunctuation('5'));
    try testing.expect(!isPunctuation(0x410)); // Cyrillic А (Lu, letter)
    try testing.expect(isPunctuation(0x1F600)); // emoji face is So (symbol) — the spec counts symbols as punctuation
    try testing.expect(!isPunctuation(0xFE0F)); // variation selector (Mn)
    try testing.expect(!isPunctuation(0x20E3)); // combining enclosing keycap (Me)
}

test "unicode: boundary values for binary search" {
    // Just below, inside, and just above the first and last ranges.
    try testing.expect(!isPunctuation(0x20));
    try testing.expect(isPunctuation(0x21));
    try testing.expect(isPunctuation(0x2F));
    try testing.expect(!isPunctuation(0x30));
    try testing.expect(!isPunctuation(0x1FBCB));
    try testing.expect(isPunctuation(0x1FBCA));
    try testing.expect(!isPunctuation(0x10FFFF + 0)); // unassigned plane end
}

test "unicode: decode and decodePrev across UTF-8" {
    const bytes = "a\xC2\xA9\xF0\x9F\x98\x80"; // 'a', ©, 😀
    try testing.expectEqual(@as(?u21, 'a'), decode(bytes, 0));
    try testing.expectEqual(@as(?u21, 0xA9), decode(bytes, 1));
    try testing.expectEqual(@as(?u21, 0x1F600), decode(bytes, 3));
    try testing.expectEqual(@as(?u21, null), decode(bytes, 7));

    try testing.expectEqual(@as(?u21, 'a'), decodePrev(bytes, 1));
    try testing.expectEqual(@as(?u21, 0xA9), decodePrev(bytes, 3));
    try testing.expectEqual(@as(?u21, 0x1F600), decodePrev(bytes, 7));
    try testing.expectEqual(@as(?u21, null), decodePrev(bytes, 0));
}

test "unicode: malformed UTF-8 degrades to non-whitespace non-punctuation" {
    // A lone continuation byte is not a valid sequence.
    try testing.expectEqual(@as(?u21, null), decode("\x80", 0));
    try testing.expectEqual(@as(?u21, null), decodePrev("\x80", 1));
    // A truncated multi-byte sequence is invalid.
    try testing.expectEqual(@as(?u21, null), decode("\xC3", 0));
    // decodePrev walks back over continuation bytes to the lead byte.
    try testing.expectEqual(@as(?u21, 0xE9), decodePrev("\xC3\xA9", 2));
}
