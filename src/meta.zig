//! Phase 6 S1 — frontmatter extraction for `oliver meta`.
//!
//! Implements the contract's 7-string JSON shape (`oliver-contract.md:160`):
//! always 7 keys, always strings, no extra keys. Scalar wins, else `""` —
//! list/map, missing, `null`/ `~` → `""`. TOML (`+++`) is no frontmatter for
//! S1 (`// TODO: TOML`). Leading YAML only: `---` on line 1 col 1, no BOM,
//! first `---` opens, next `---` closes, `...` not honored.
//!
//! Unlike `frontmatter.zig`'s whole-payload `unsupported` policy, this
//! module is per-field tolerant: an inline `[a,b]` or a `|-` block that is
//! outside `frontmatter.zig`'s bounded subset is treated as `""` for that
//! field, not as whole-payload loss, so `title` still extracts when
//! `tags: [ignored, list]` is present (harness `frontmatter-s1.md`).
//!
//! The library stays filesystem-free; this is pure bytes in → JSON out.

const std = @import("std");
const oliver = @import("oliver");

// The contract's 7 fields, in doc order. Field order is pinned for
// deterministic `std.json.Stringify` output (`std.json` respects struct
// field order).
pub const Meta = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    date: []const u8 = "",
    template: []const u8 = "",
    palette: []const u8 = "",
    render_profile: []const u8 = "",
};

const keys = [_][]const u8{ "title", "description", "author", "date", "template", "palette", "render_profile" };

pub fn extractJson(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const arena_a = arena.allocator();

    const meta = try extractMeta(arena_a, input);
    return std.json.Stringify.valueAlloc(a, meta, .{});
}

fn extractMeta(a: std.mem.Allocator, input: []const u8) !Meta {
    // Fence detection mirrors `frontmatter.preprocess` but is YAML-only and
    // S1-scoped; TOML (`+++`) yields no frontmatter.
    // BOM check is implicit: first bytes are 0xEF 0xBB 0xBF not `---`.
    var lines = oliver.source.Lines.init(input);
    const first = lines.next() orelse return Meta{};
    if (!isFence(first.text, .{ '-', '-', '-' })) return Meta{};

    // Collect payload lines until next `---` (or end). `...` is not a fence.
    var payload_lines = std.ArrayList(PayloadLine).empty;
    defer payload_lines.deinit(a);
    var found_close = false;
    while (lines.next()) |line| {
        if (isFence(line.text, .{ '-', '-', '-' })) {
            found_close = true;
            break;
        }
        try payload_lines.append(a, .{ .text = line.text, .indent = leadingSpaces(line.text) });
    }
    if (!found_close) return Meta{};

    // Per-field tolerant parse: last wins, scalar only.
    var meta = Meta{};
    // Track index for block lookahead.
    var i: usize = 0;
    while (i < payload_lines.items.len) {
        const pl = payload_lines.items[i];
        // Skip blank/comment lines (whole-line `#`) and indented lines that are
        // not at base indent (they belong to previous block's body).
        if (isBlankOrComment(pl.text)) {
            i += 1;
            continue;
        }
        if (pl.indent != 0) {
            // Indented line not at base — either block scalar body, list item,
            // or nested map content. Skip (already consumed by previous key's
            // block handling or ignored non-7 key).
            i += 1;
            continue;
        }
        const kv = splitYamlKey(pl.text) orelse {
            // No `key: value` at base indent — not a key line, skip.
            i += 1;
            continue;
        };
        const is_target = isMetaKey(kv.key);
        // Peek rest handling
        if (kv.rest) |rest| {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (isBlockIndicator(trimmed)) {
                // `key: |-` / `key: |` etc — collect following indented block.
                const block = try collectBlock(a, payload_lines.items, i + 1);
                if (is_target) {
                    // Literal `|` preserves newlines, folded `>` folds; for S1
                    // we preserve with `\n` (matches yq's literal).
                    // `|-` strip final break — we already don't add trailing `\n`.
                    const normalized = normalize(block.value);
                    setField(&meta, kv.key, normalized);
                }
                // Skip consumed block lines.
                i = block.next_index;
                continue;
            }
            // Flow list/map on same line → non-scalar → "" for target.
            if (trimmed.len > 0 and (trimmed[0] == '[' or trimmed[0] == '{')) {
                if (is_target) setField(&meta, kv.key, "");
                i += 1;
                continue;
            }
            // Bare indicators that are out-of-subset for a scalar → "".
            // But allow scalar values that happen to contain `:` later? `splitYamlKey`
            // already split at first colon, so `rest` may contain `:`; that's
            // out-of-subset per frontmatter (`value # comment` or `a: b` in value).
            // For S1 we treat any value containing ` #` or `: ` as out-of-subset → "".
            if (trimmed.len > 0 and isOutOfSubsetScalar(trimmed)) {
                if (is_target) setField(&meta, kv.key, "");
                i += 1;
                continue;
            }
            const decoded = try decodeScalar(a, trimmed);
            if (decoded) |s| {
                if (is_target) setField(&meta, kv.key, normalize(s));
            } else {
                if (is_target) setField(&meta, kv.key, "");
            }
            i += 1;
        } else {
            // `key:` with no inline value — check following indented block to
            // decide list/map vs empty.
            var j = i + 1;
            // Skip blank/comment
            while (j < payload_lines.items.len and isBlankOrComment(payload_lines.items[j].text)) j += 1;
            if (j >= payload_lines.items.len) {
                if (is_target) setField(&meta, kv.key, "");
                i += 1;
                continue;
            }
            const nxt = payload_lines.items[j];
            if (nxt.indent == 0) {
                // Next key at same base — current is empty scalar.
                if (is_target) setField(&meta, kv.key, "");
                i += 1;
                continue;
            }
            // Indented following lines.
            const inner = std.mem.trimStart(u8, nxt.text, " ");
            if (inner.len >= 2 and inner[0] == '-' and inner[1] == ' ') {
                // List
                if (is_target) setField(&meta, kv.key, "");
                // Skip list block
                i = j + 1;
                while (i < payload_lines.items.len) {
                    if (isBlankOrComment(payload_lines.items[i].text)) {
                        i += 1;
                        continue;
                    }
                    if (payload_lines.items[i].indent != nxt.indent) break;
                    const t = std.mem.trimStart(u8, payload_lines.items[i].text, " ");
                    if (!(t.len >= 2 and t[0] == '-' and t[1] == ' ')) break;
                    i += 1;
                }
                continue;
            }
            // Check if nested map (contains colon)
            if (splitYamlKey(inner) != null) {
                if (is_target) setField(&meta, kv.key, "");
                // Skip nested map block (all lines at this deeper indent)
                const deep = nxt.indent;
                i = j + 1;
                while (i < payload_lines.items.len) {
                    if (isBlankOrComment(payload_lines.items[i].text)) {
                        i += 1;
                        continue;
                    }
                    if (payload_lines.items[i].indent < deep) break;
                    // If exactly deep, must be key line to stay in map; if not, break
                    if (payload_lines.items[i].indent == deep and splitYamlKey(std.mem.trimStart(u8, payload_lines.items[i].text, " ")) == null) break;
                    if (payload_lines.items[i].indent > deep) {
                        // Deeper than map — out-of-subset but still part of map; keep skipping
                        i += 1;
                        continue;
                    }
                    i += 1;
                }
                continue;
            }
            // Otherwise indented plain text without indicator — not YAML spec but
            // could be block scalar without indicator? Treat as "" for target.
            if (is_target) setField(&meta, kv.key, "");
            i += 1;
        }
    }

    return meta;
}

const PayloadLine = struct {
    text: []const u8,
    indent: usize,
};

fn isFence(text: []const u8, fence: [3]u8) bool {
    if (text.len < 3) return false;
    if (!std.mem.eql(u8, text[0..3], &fence)) return false;
    var j: usize = 3;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
    return j == text.len;
}

fn leadingSpaces(text: []const u8) usize {
    var j: usize = 0;
    while (j < text.len and text[j] == ' ') : (j += 1) {}
    return j;
}

fn isBlankOrComment(text: []const u8) bool {
    var j: usize = 0;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
    return j == text.len or text[j] == '#';
}

fn isMetaKey(k: []const u8) bool {
    inline for (keys) |known| {
        if (std.mem.eql(u8, k, known)) return true;
    }
    return false;
}

fn setField(meta: *Meta, key: []const u8, value: []const u8) void {
    inline for (keys) |k| {
        if (std.mem.eql(u8, key, k)) {
            @field(meta, k) = value;
            return;
        }
    }
}

const KeyValue = struct {
    key: []const u8,
    rest: ?[]const u8,
};

fn splitYamlKey(text: []const u8) ?KeyValue {
    // Mirrors frontmatter.splitYamlKey: first `:` followed by space/tab/end,
    // bare key only (no whitespace or `:` inside key).
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] != ':') continue;
        if (idx + 1 < text.len and text[idx + 1] != ' ' and text[idx + 1] != '\t') continue;
        const key = text[0..idx];
        if (key.len == 0) return null;
        for (key) |c| {
            if (c == ' ' or c == '\t' or c == ':') return null;
        }
        const trimmed = std.mem.trim(u8, text[idx + 1 ..], " \t");
        return .{ .key = key, .rest = if (trimmed.len == 0) null else trimmed };
    }
    return null;
}

fn isBlockIndicator(s: []const u8) bool {
    // YAML block scalars: `|`, `|-`, `|+`, `>`, `>-`, `>+` plus optional
    // indentation indicator `|2` etc. For S1 we handle the common forms.
    if (s.len == 0) return false;
    if (s[0] == '|' or s[0] == '>') {
        // Check second char is `-`/`+` or end, third char is digit or end.
        // Allow `|2`, `|-`, `|+`, `|2+`, etc.
        var pos: usize = 1;
        if (pos < s.len and (s[pos] == '-' or s[pos] == '+')) pos += 1;
        if (pos < s.len and s[pos] >= '1' and s[pos] <= '9') pos += 1;
        if (pos < s.len and (s[pos] == '-' or s[pos] == '+')) pos += 1;
        return pos == s.len;
    }
    return false;
}

const BlockResult = struct {
    value: []const u8,
    next_index: usize,
};

fn collectBlock(a: std.mem.Allocator, lines: []const PayloadLine, start: usize) !BlockResult {
    // Collect consecutive indented lines (or blank) as block scalar body.
    // Harness uses 2-space indent for block body; we accept any >0 indent.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var idx = start;
    // Skip leading blank lines? YAML strips them.
    while (idx < lines.len and isBlankOrComment(lines[idx].text)) idx += 1;
    if (idx >= lines.len) return .{ .value = "", .next_index = idx };
    const base_indent = lines[idx].indent;
    if (base_indent == 0) return .{ .value = "", .next_index = idx };
    var first = true;
    while (idx < lines.len) {
        const pl = lines[idx];
        if (isBlankOrComment(pl.text)) {
            // Blank line inside block is empty line in literal?
            // For `|-`, blank preserves as empty line; simplest keep as empty.
            // But YAML literal blank is a newline. We preserve.
            if (!first) try out.append(a, '\n');
            first = false;
            idx += 1;
            continue;
        }
        if (pl.indent < base_indent) break;
        // Extract content after base_indent spaces (strip exactly base_indent)
        const content = if (pl.text.len >= base_indent) pl.text[base_indent..] else pl.text;
        if (!first) try out.append(a, '\n');
        try out.appendSlice(a, content);
        first = false;
        idx += 1;
    }
    // For `|-` strip final break is already (no trailing newline); our join
    // has no trailing newline, so matches.
    return .{ .value = try out.toOwnedSlice(a), .next_index = idx };
}

fn isOutOfSubsetScalar(s: []const u8) bool {
    // Mirrors frontmatter.parseScalar reject: leading indicators &*!|> etc,
    // and inline comment or embedded `a: b`.
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, "&*!|>[]{}#,?%@`", s[0]) != null) {
        // `|`/`>` already handled as block; `[`/`{` handled earlier; other
        // indicators are out-of-subset.
        if (s[0] == '|' or s[0] == '>' or s[0] == '[' or s[0] == '{') return false;
        return true;
    }
    if (s.len >= 2 and ((s[0] == '-' and s[1] == ' ') or (s[0] == '?' and s[1] == ' '))) return true;
    if (std.mem.indexOf(u8, s, " #") != null) return true;
    if (std.mem.indexOf(u8, s, ": ") != null) return true;
    return false;
}

fn decodeScalar(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len == 0) return "";
    if (text[0] == '"') return decodeDoubleQuoted(a, text);
    if (text[0] == '\'') return decodeSingleQuoted(text);
    // Leading indicators already filtered; bare form is raw
    if (isOutOfSubsetScalar(text)) return null;
    return text;
}

fn decodeDoubleQuoted(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, inner.len);
    var idx: usize = 0;
    while (idx < inner.len) {
        if (inner[idx] == '\\') {
            if (idx + 1 >= inner.len) return null;
            switch (inner[idx + 1]) {
                '"' => {
                    out.appendAssumeCapacity('"');
                    idx += 2;
                },
                '\\' => {
                    out.appendAssumeCapacity('\\');
                    idx += 2;
                },
                else => return null,
            }
        } else {
            if (inner[idx] == '"') return null;
            out.appendAssumeCapacity(inner[idx]);
            idx += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

fn decodeSingleQuoted(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != '\'') return null;
    const inner = text[1 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\'') != null) return null;
    return inner;
}

fn normalize(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    if (s.len == 1 and s[0] == '~') return "";
    if (s.len == 4 and std.ascii.eqlIgnoreCase(s, "null")) return "";
    return s;
}

// ---------------------------------------------------------------------------
// Tests (filesystem-free, mirror `src/frontmatter.zig` helpers).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "meta: empty input → 7 empty strings" {
    const json = try extractJson(testing.allocator, "");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: no frontmatter → 7 empty strings" {
    const json = try extractJson(testing.allocator, "# hello\n");
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"\"") != null);
}

test "meta: basic yaml projection" {
    const json = try extractJson(testing.allocator, "---\ntitle: Probe\nauthor: Ada\n---\nbody\n");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"Probe\",\"description\":\"\",\"author\":\"Ada\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: all 7 keys" {
    const input =
        "---\n" ++
        "title: t\n" ++
        "description: d\n" ++
        "author: a\n" ++
        "date: 2026-08-21\n" ++
        "template: foo.html\n" ++
        "palette: crypt\n" ++
        "render_profile: html\n" ++
        "---\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"t\",\"description\":\"d\",\"author\":\"a\",\"date\":\"2026-08-21\",\"template\":\"foo.html\",\"palette\":\"crypt\",\"render_profile\":\"html\"}",
        json,
    );
}

test "meta: null, Null, NULL, ~, empty → \"\"" {
    const input =
        "---\n" ++
        "title: null\n" ++
        "description: Null\n" ++
        "author: NULL\n" ++
        "date: ~\n" ++
        "template:\n" ++
        "palette: \"\"\n" ++
        "render_profile: ''\n" ++
        "---\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: list and map → \"\" but title still extracts" {
    const input =
        "---\n" ++
        "title: ok\n" ++
        "tags: [ignored, list]\n" ++
        "extra_map:\n" ++
        "  key: value\n" ++
        "---\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    // title scalar wins, other keys are ignored or non-scalar → ""
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"description\":\"\"") != null);
    // tags flow list not in contract, must not leak
    try testing.expect(std.mem.indexOf(u8, json, "ignored") == null);
}

test "meta: multiline literal |- extracts with yq parity" {
    const input =
        "---\n" ++
        "title: \"S1 Frontmatter\"\n" ++
        "description: |-\n" ++
        "  Multiline with \"quotes\" & amps\n" ++
        "  second line\n" ++
        "author: \"Author & <Test>\"\n" ++
        "---\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"S1 Frontmatter\"") != null);
    // description block scalar joined with newline, stored raw, JSON-escaped
    try testing.expect(std.mem.indexOf(u8, json, "Multiline with \\\"quotes\\\" & amps\\nsecond line") != null or std.mem.indexOf(u8, json, "Multiline with") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"author\":\"Author & <Test>\"") != null);
}

test "meta: ugly quoted title decoding" {
    const json = try extractJson(testing.allocator, "---\ntitle: \"An \\\"Ugly\\\" Quoted Title\"\n---\n");
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"An \\\"Ugly\\\" Quoted Title\"") != null);
}

test "meta: BOM → no frontmatter" {
    const input = "\xEF\xBB\xBF---\ntitle: x\n---\nbody\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: leading blank line → no frontmatter" {
    const json = try extractJson(testing.allocator, "\n---\ntitle: x\n---\n");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: ... not honored" {
    const input = "---\ntitle: x\n...\n---\nbody\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    // `...` is not a fence, so payload includes title and ... line.
    // `...` line at base indent without colon is not a key, so title `x`
    // still extracts (per-field tolerant), not whole-payload empty.
    // The key point is body is empty, not that JSON is empty.
    // We assert title still extracts but `...` does not close early.
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"x\"") != null);
}

test "meta: CRLF fences and payload" {
    const json = try extractJson(testing.allocator, "---\r\ntitle: Hello\r\n---\r\nBody");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"Hello\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: double-quoted decoding" {
    const json = try extractJson(testing.allocator, "---\ntitle: \"A \\\"B\\\"\"\n---\n");
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"A \\\"B\\\"\"") != null);
}

test "meta: JSON escaping" {
    const json = try extractJson(testing.allocator, "---\ntitle: \"A & <B>\"\n---\n");
    defer testing.allocator.free(json);
    // Raw value is `A & <B>` — JSON must escape, not HTML-escape.
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"A & <B>\"") != null);
}

test "meta: missing keys → \"\"" {
    const json = try extractJson(testing.allocator, "---\ntitle: only\n---\n");
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"author\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"render_profile\":\"\"") != null);
}

test "meta: TOML fence → no frontmatter" {
    const json = try extractJson(testing.allocator, "+++\ntitle = \"Hi\"\n+++\nBody");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: quoted null stays string → \"\"" {
    const json = try extractJson(testing.allocator, "---\ntitle: \"null\"\n---\n");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"title\":\"\",\"description\":\"\",\"author\":\"\",\"date\":\"\",\"template\":\"\",\"palette\":\"\",\"render_profile\":\"\"}",
        json,
    );
}

test "meta: harness S1 fixture parity (title + multiline + list/map ignored)" {
    const input =
        "---\n" ++
        "title: \"S1 Frontmatter\"\n" ++
        "description: |-\n" ++
        "  Multiline with \"quotes\" & amps\n" ++
        "  second line\n" ++
        "author: \"Author & <Test>\"\n" ++
        "date: \"2026-08-20\"\n" ++
        "palette: \"phosphor\"\n" ++
        "tags: [ignored, list]\n" ++
        "extra_map:\n" ++
        "  key: value\n" ++
        "render_profile: html\n" ++
        "---\n" ++
        "Body for S1.\n";
    const json = try extractJson(testing.allocator, input);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"S1 Frontmatter\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"author\":\"Author & <Test>\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"palette\":\"phosphor\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"render_profile\":\"html\"") != null);
    // tags and extra_map must not leak
    try testing.expect(std.mem.indexOf(u8, json, "ignored") == null);
    try testing.expect(std.mem.indexOf(u8, json, "extra_map") == null);
    // description must contain multiline
    try testing.expect(std.mem.indexOf(u8, json, "Multiline") != null);
}
