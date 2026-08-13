#!/usr/bin/env python3
"""Regenerate the named-entity table embedded in src/entities.zig.

Data source: the WHATWG HTML specification's authoritative entity list,
<https://html.spec.whatwg.org/entities.json>. The CommonMark 0.31.2 spec
(§2.5) names exactly this document as the authoritative source for valid
entity references and their code points; it is an HTML-specification data
source, not any parser implementation.

CommonMark 0.31.2 §2.5 defines an entity reference as `&` + any of the
valid HTML5 entity names + `;`, so only the *semicolon-terminated* keys of
entities.json are emitted (the legacy no-semicolon forms are not valid
CommonMark references, matching spec example 29 `&copy` -> `&amp;copy`).
Each entity maps to one or two Unicode code points (no HTML5 entity maps
to more than two).

The script emits the table as a sorted array of fixed records, so lookup
is an exact binary search. Run:

    python3 tools/gen-entities.py --out src/entities.zig

then `zig fmt src/entities.zig` to normalize formatting. The file header
records the source URL and the generated date-independent facts.
"""

import argparse
import json


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--entities", default="/tmp/entities.json",
                   help="path to the WHATWG entities.json data file")
    p.add_argument("--out", default="src/entities.zig",
                   help="output Zig file")
    return p.parse_args()


def main():
    args = parse_args()
    with open(args.entities, encoding="utf-8") as f:
        data = json.load(f)

    rows = []
    for key, value in data.items():
        # CommonMark requires the trailing semicolon.
        if not key.endswith(";"):
            continue
        name = key[1:-1]  # strip "&" and ";"
        cps = value["codepoints"]
        assert 1 <= len(cps) <= 2, (name, cps)
        rows.append((name, cps[0], cps[1] if len(cps) == 2 else 0))
    rows.sort(key=lambda r: r[0])

    lines = []
    lines.append("//! Named character references (CommonMark 0.31.2 §2.5).")
    lines.append("//!")
    lines.append("//! Generated from the WHATWG HTML specification's authoritative entity")
    lines.append("//! list, entities.json (https://html.spec.whatwg.org/entities.json) — an")
    lines.append("//! HTML-specification data source, not any parser implementation — by")
    lines.append("//! tools/gen-entities.py. Only the semicolon-terminated names are kept,")
    lines.append("//! because CommonMark entity references require the trailing `;`.")
    lines.append("//!")
    lines.append("//! Do not edit by hand; regenerate with tools/gen-entities.py.")
    lines.append("")
    lines.append("const std = @import(\"std\");")
    lines.append("")
    lines.append("/// One named entity: its name (without `&`/`;`) and its one or two")
    lines.append("/// code points (`b` is 0 for single-code-point entities). Sorted by name.")
    lines.append("pub const Entity = struct {")
    lines.append("    name: []const u8,")
    lines.append("    a: u21,")
    lines.append("    b: u21,")
    lines.append("};")
    lines.append("")
    lines.append(f"/// {len(rows)} named entities, sorted for binary search.")
    lines.append("pub const entities = [_]Entity{")
    for name, a, b in rows:
        lines.append(f'    .{{ .name = "{name}", .a = 0x{a:X}, .b = 0x{b:X} }},')
    lines.append("};")
    lines.append("")
    lines.append("/// Looks up a named entity by its exact (case-sensitive) name without")
    lines.append("/// the `&` and `;`. Returns the code points, or null when the name is")
    lines.append("/// not a valid HTML5 entity name.")
    lines.append("pub fn lookup(name: []const u8) ?[2]u21 {")
    lines.append("    var lo: usize = 0;")
    lines.append("    var hi: usize = entities.len;")
    lines.append("    while (lo < hi) {")
    lines.append("        const mid = lo + (hi - lo) / 2;")
    lines.append("        const cmp = std.mem.order(u8, entities[mid].name, name);")
    lines.append("        switch (cmp) {")
    lines.append("            .lt => lo = mid + 1,")
    lines.append("            .gt => hi = mid,")
    lines.append("            .eq => return .{ entities[mid].a, entities[mid].b },")
    lines.append("        }")
    lines.append("    }")
    lines.append("    return null;")
    lines.append("}")
    lines.append("")
    lines.append('test "entities: corpus names resolve and unknown names do not" {')
    for name in ["amp", "copy", "ouml", "AElig", "Dcaron", "frac34", "HilbertSpace",
                 "DifferentialD", "ClockwiseContourIntegral", "ngE", "nbsp", "quot",
                 "gt", "lt", "auml"]:
        lines.append(f'    try std.testing.expect(lookup("{name}") != null);')
    lines.append('    try std.testing.expect(lookup("MadeUpEntity") == null);')
    lines.append('    try std.testing.expect(lookup("ThisIsNotDefined") == null);')
    lines.append('    try std.testing.expectEqual(@as(?[2]u21, .{ 0x26, 0 }), lookup("amp"));')
    lines.append('    try std.testing.expectEqual(@as(?[2]u21, .{ 0x2267, 0x338 }), lookup("ngE"));')
    lines.append("}")
    lines.append("")
    lines.append("/// The decoded form of an entity or numeric character reference: its UTF-8")
    lines.append("/// bytes and the index just past the terminating `;` in the source.")
    lines.append("pub const Decoded = struct {")
    lines.append("    bytes: [8]u8,")
    lines.append("    len: u8,")
    lines.append("    next: usize,")
    lines.append("};")
    lines.append("")
    lines.append("/// Decodes the entity or numeric character reference whose `&` is at")
    lines.append("/// `src[amp]`, mirroring the reference implementation's §2.5 rules: named")
    lines.append("/// references must be a valid HTML5 entity name followed by `;`; decimal")
    lines.append("/// references take 1-7 digits, hexadecimal 1-6; code point 0, surrogates,")
    lines.append("/// and values at or above U+110000 become U+FFFD. Returns null when no")
    lines.append("/// reference starts at `amp` (the `&` is literal text).")
    lines.append("pub fn decodeAt(src: []const u8, amp: usize) ?Decoded {")
    lines.append("    if (amp + 2 > src.len or src[amp] != '&') return null;")
    lines.append("    if (src[amp + 1] == '#') return decodeNumeric(src, amp);")
    lines.append("    return decodeNamed(src, amp);")
    lines.append("}")
    lines.append("")
    lines.append("fn decodeNumeric(src: []const u8, amp: usize) ?Decoded {")
    lines.append("    var i = amp + 2;")
    lines.append("    var base: u32 = 10;")
    lines.append("    var max_digits: usize = 7;")
    lines.append("    if (i < src.len and (src[i] == 'x' or src[i] == 'X')) {")
    lines.append("        i += 1;")
    lines.append("        base = 16;")
    lines.append("        max_digits = 6;")
    lines.append("    }")
    lines.append("    const digit_start = i;")
    lines.append("    var cp: u32 = 0;")
    lines.append("    while (i < src.len) : (i += 1) {")
    lines.append("        const c = src[i];")
    lines.append("        const d: u32 = switch (c) {")
    lines.append("            '0'...'9' => c - '0',")
    lines.append("            'a'...'f' => if (base == 16) c - 'a' + 10 else break,")
    lines.append("            'A'...'F' => if (base == 16) c - 'A' + 10 else break,")
    lines.append("            else => break,")
    lines.append("        };")
    lines.append("        cp = @min(cp * base + d, 0x110000);")
    lines.append("    }")
    lines.append("    const num_digits = i - digit_start;")
    lines.append("    if (num_digits == 0 or num_digits > max_digits or i >= src.len or src[i] != ';') return null;")
    lines.append("    if (cp == 0 or (cp >= 0xD800 and cp <= 0xDFFF) or cp >= 0x110000) cp = 0xFFFD;")
    lines.append("    var out: [8]u8 = undefined;")
    lines.append("    const len = encodeUtf8(@intCast(cp), &out);")
    lines.append("    return .{ .bytes = out, .len = len, .next = i + 1 };")
    lines.append("}")
    lines.append("")
    lines.append("fn decodeNamed(src: []const u8, amp: usize) ?Decoded {")
    lines.append("    var i = amp + 1;")
    lines.append("    while (i < src.len and src[i] != ';' and src[i] != ' ') : (i += 1) {}")
    lines.append("    if (i >= src.len or src[i] != ';') return null;")
    lines.append("    const cps = lookup(src[amp + 1 .. i]) orelse return null;")
    lines.append("    var out: [8]u8 = undefined;")
    lines.append("    var len: u8 = encodeUtf8(cps[0], &out);")
    lines.append("    if (cps[1] != 0) len += encodeUtf8(cps[1], out[len..]);")
    lines.append("    return .{ .bytes = out, .len = len, .next = i + 1 };")
    lines.append("}")
    lines.append("")
    lines.append("/// UTF-8 encodes `cp` into `out` (at most 4 bytes) and returns its length.")
    lines.append("fn encodeUtf8(cp: u21, out: []u8) u8 {")
    lines.append("    if (cp < 0x80) {")
    lines.append("        out[0] = @intCast(cp);")
    lines.append("        return 1;")
    lines.append("    } else if (cp < 0x800) {")
    lines.append("        out[0] = @intCast(0xC0 | (cp >> 6));")
    lines.append("        out[1] = @intCast(0x80 | (cp & 0x3F));")
    lines.append("        return 2;")
    lines.append("    } else if (cp < 0x10000) {")
    lines.append("        out[0] = @intCast(0xE0 | (cp >> 12));")
    lines.append("        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));")
    lines.append("        out[2] = @intCast(0x80 | (cp & 0x3F));")
    lines.append("        return 3;")
    lines.append("    } else {")
    lines.append("        out[0] = @intCast(0xF0 | (cp >> 18));")
    lines.append("        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));")
    lines.append("        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));")
    lines.append("        out[3] = @intCast(0x80 | (cp & 0x3F));")
    lines.append("        return 4;")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append('test "entities: decodeAt resolves the corpus forms" {')
    lines.append("    try std.testing.expectEqualStrings(\"\\u{A0} & © Æ Ď\", decodeAll(\"&nbsp; &amp; &copy; &AElig; &Dcaron;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"# Ӓ Ϡ �\", decodeAll(\"&#35; &#1234; &#992; &#0;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"\\\" ആ ಫ\", decodeAll(\"&#X22; &#XD06; &#xcab;\"));")
    lines.append("    // Nonentities stay literal.")
    lines.append("    try std.testing.expectEqualStrings(\"&nbsp &x; &#; &#x;\", decodeAll(\"&nbsp &x; &#; &#x;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"&#87654321;\", decodeAll(\"&#87654321;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"&#abcdef0;\", decodeAll(\"&#abcdef0;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"&copy\", decodeAll(\"&copy\"));")
    lines.append("    try std.testing.expectEqualStrings(\"&MadeUpEntity;\", decodeAll(\"&MadeUpEntity;\"));")
    lines.append("    // Structural characters stay literal (&#42; is not a delimiter).")
    lines.append("    try std.testing.expectEqualStrings(\"*foo*\", decodeAll(\"&#42;foo&#42;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"foo\\n\\nbar\", decodeAll(\"foo&#10;&#10;bar\"));")
    lines.append("    try std.testing.expectEqualStrings(\"\\tfoo\", decodeAll(\"&#9;foo\"));")
    lines.append("}")
    lines.append("")
    lines.append("test \"entities: decodeAt edge cases\" {")
    lines.append("    // A prefix of a real name is not an entity.")
    lines.append("    try std.testing.expectEqualStrings(\"&noti;\", decodeAll(\"&noti;\"));")
    lines.append("    // Entity names are exact (case-sensitive): mixed case is not a reference.")
    lines.append("    try std.testing.expectEqualStrings(\"&NotEQual;\", decodeAll(\"&NotEQual;\"));")
    lines.append("    try std.testing.expectEqualStrings(\"©\", decodeAll(\"&copy;\"));")
    lines.append("    // Two-codepoint entity.")
    lines.append("    try std.testing.expectEqualStrings(\"≧̸\", decodeAll(\"&ngE;\"));")
    lines.append("    // & at the very end.")
    lines.append("    try std.testing.expectEqualStrings(\"a &\", decodeAll(\"a &\"));")
    lines.append("}")
    lines.append("")
    lines.append("var decode_scratch: [256]u8 = undefined;")
    lines.append("fn decodeAll(src: []const u8) []const u8 {")
    lines.append("    var n: usize = 0;")
    lines.append("    var i: usize = 0;")
    lines.append("    while (i < src.len) {")
    lines.append("        if (src[i] == '&') {")
    lines.append("            if (decodeAt(src, i)) |dec| {")
    lines.append("                @memcpy(decode_scratch[n .. n + dec.len], dec.bytes[0..dec.len]);")
    lines.append("                n += dec.len;")
    lines.append("                i = dec.next;")
    lines.append("                continue;")
    lines.append("            }")
    lines.append("        }")
    lines.append("        decode_scratch[n] = src[i];")
    lines.append("        n += 1;")
    lines.append("        i += 1;")
    lines.append("    }")
    lines.append("    return decode_scratch[0..n];")
    lines.append("}")
    lines.append("")

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
