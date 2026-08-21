//! Phase 6 S2 — template dialect for `oliver wrap`.
//!
//! Implements the 7-token dialect (`oliver-contract.md:115-145`):
//!
//!   $title$ $description$ $author$ $date$ $palette$  → html_escape
//!   $assets_root$ $body$                              → literal
//!
//! Conditional blocks: `$if(name)$...$endif$` for the five meta fields
//! (title→palette, first `$endif$` closes, no nesting, verbatim unknown).
//! Empty/null → block removed; all `$if$` resolved before literal subs.
//!
//! The library stays filesystem-free; this is pure bytes in → bytes out.

const std = @import("std");

/// The JSON wire type for the 5 meta fields. Unknown fields are
/// silently ignored (the S1 contract also ships `template` and
/// `render_profile` which we don't need here).
const MetaJson = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    palette: ?[]const u8 = null,
};

/// The JSON parse result. The `value` field contains the 5 optional
/// strings; the arena owns the backing memory. The caller must keep
/// this struct alive while accessing `value` fields.
pub const ParsedMeta = std.json.Parsed(MetaJson);

/// Resolves a field name to its value (for `$if$` lookup and substitution).
/// Returns empty string for missing/null fields (the S1 contract
/// guarantees all 7 keys, but being defensive is free).
fn fieldVal(m: ParsedMeta, name: []const u8) []const u8 {
    const v = m.value;
    if (std.mem.eql(u8, name, "title")) return v.title orelse "";
    if (std.mem.eql(u8, name, "description")) return v.description orelse "";
    if (std.mem.eql(u8, name, "author")) return v.author orelse "";
    if (std.mem.eql(u8, name, "date")) return v.date orelse "";
    if (std.mem.eql(u8, name, "palette")) return v.palette orelse "";
    return "";
}

/// Whether the given name is a recognized meta field with a non-empty value.
fn isNonEmpty(m: ParsedMeta, name: []const u8) bool {
    return fieldVal(m, name).len > 0;
}

/// Resolves the template dialect into the output writer.
///
/// - `$title$`/`$description$`/`$author$`/`$date$`/`$palette$` → html-escaped meta value
/// - `$assets_root$` → literal (unescaped)
/// - `$body$` → literal (unescaped, trusted HTML)
/// - `$if(name)$...$endif$` → conditional: known meta field + non-empty → keep interior;
///   known meta field + empty → remove block; unknown name → verbatim passthrough
/// - Unknown `$word$` → verbatim
pub fn wrap(
    a: std.mem.Allocator,
    meta_json: []const u8,
    template: []const u8,
    body: []const u8,
    assets_root: []const u8,
    out: anytype,
) !void {
    // Parse the meta JSON. The `parsed` struct owns the arena that backs
    // the string slices; it must stay alive until we're done reading them.
    var parsed = std.json.parseFromSlice(MetaJson, a, meta_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MetaJsonParseError;
    defer parsed.deinit();

    // Phase 1: strip $if(name)$...$endif$ blocks.
    const stripped = try stripIfs(a, template, parsed);
    defer a.free(stripped);

    // Phase 2: substitute the 7 literal tokens.
    try substitute(stripped, parsed, body, assets_root, out);
}

// ---------------------------------------------------------------------------
// Phase 1: $if$ block stripping.
// ---------------------------------------------------------------------------

/// Strips all `$if(name)$...$endif$` blocks. Rules (from issue #108):
/// - Known meta field (title/description/author/date/palette) + non-empty → keep interior
/// - Known meta field + empty/null → remove entire block (including interior newlines)
/// - Unknown name → verbatim passthrough (the `$if(unknown)$...$endif$` is literal text)
/// - First `$endif$` closes each opener; no nesting
fn stripIfs(a: std.mem.Allocator, template: []const u8, m: ParsedMeta) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(a, template.len);
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < template.len) {
        // Scan for the literal "$if(" substring.
        const if_start = findChar(template, i, '$');
        if (if_start == null) {
            try out.appendSlice(a, template[i..]);
            break;
        }
        // Verify the next 3 chars are 'i', 'f', '('.
        const fs = if_start.?;
        if (fs + 3 >= template.len or
            template[fs + 1] != 'i' or
            template[fs + 2] != 'f' or
            template[fs + 3] != '(')
        {
            // Not a $if$ — write everything up to and including this
            // $, then continue scanning past it.
            if (fs + 1 > i) try out.appendSlice(a, template[i .. fs + 1]);
            i = fs + 1;
            continue;
        }

        // Text before the $if$.
        if (fs > i) try out.appendSlice(a, template[i..fs]);

        // Find the closing )$ of $if(name)$ — scan after the '('.
        const close = std.mem.indexOf(u8, template[fs + 4 ..], ")$");
        if (close == null) {
            try out.appendSlice(a, template[fs..]);
            break;
        }
        const name = template[fs + 4 .. fs + 4 + close.?];
        const after_if_close = fs + 4 + close.? + 2; // past )$

        // Find first $endif$.
        const end = findEndif(template, after_if_close);
        if (end == null) {
            try out.appendSlice(a, template[fs..]);
            break;
        }
        const interior = template[after_if_close..end.?];
        const after_endif = end.? + 7; // len of "$endif$"

        // Unknown name → verbatim passthrough.
        if (!isKnownField(name)) {
            try out.appendSlice(a, template[fs..after_endif]);
        } else if (isNonEmpty(m, name)) {
            try out.appendSlice(a, interior);
        }
        // else: known field but empty → block removed (skip).

        i = after_endif;
    }
    return out.toOwnedSlice(a);
}

/// Whether `name` is one of the five recognized meta fields.
fn isKnownField(name: []const u8) bool {
    return std.mem.eql(u8, name, "title") or
        std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "author") or
        std.mem.eql(u8, name, "date") or
        std.mem.eql(u8, name, "palette");
}

/// Finds the next occurrence of byte `ch` in `haystack` starting at `from`.
/// Returns the absolute index or null.
fn findChar(haystack: []const u8, from: usize, ch: u8) ?usize {
    const rel = std.mem.indexOfScalar(u8, haystack[from..], ch) orelse return null;
    return from + rel;
}

/// Finds the next `$endif$` starting at `from`. Returns the index of the
/// opening `$` of `$endif$`, or null.
fn findEndif(template: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 7 <= template.len) : (i += 1) {
        if (std.mem.eql(u8, template[i .. i + 7], "$endif$")) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Phase 2: literal token substitution.
// ---------------------------------------------------------------------------

/// Substitutes the 7 recognized tokens: 5 html-escaped meta fields,
/// plus `$assets_root$` and `$body$` as literals. Unknown `$word$`
/// passes verbatim.
fn substitute(
    template: []const u8,
    m: ParsedMeta,
    body: []const u8,
    assets_root: []const u8,
    out: anytype,
) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '$') {
            const end = nextDollar(template, i);
            try out.writeAll(template[i..end]);
            i = end;
            continue;
        }
        const dollar = i;
        i += 1;
        // Find closing $.
        const close = std.mem.indexOfScalar(u8, template[i..], '$');
        if (close == null) {
            try out.writeAll(template[dollar..]);
            break;
        }
        const name = template[i .. i + close.?];
        i = i + close.? + 1; // past closing $

        if (std.mem.eql(u8, name, "assets_root")) {
            try out.writeAll(assets_root);
        } else if (std.mem.eql(u8, name, "body")) {
            try out.writeAll(body);
        } else if (isKnownField(name)) {
            try htmlEscape(out, fieldVal(m, name));
        } else {
            // Unknown token: verbatim (including $ delimiters).
            try out.writeAll(template[dollar..i]);
        }
    }
}

/// Returns the index of the next `$` or the end of the string.
fn nextDollar(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and s[i] != '$') : (i += 1) {}
    return i;
}

/// Writes `text` with HTML escaping (& < > " ' → entities), matching
/// the GAWK `html_escape` used by the rotkeeper adapter. The order
/// (& first) prevents double-escaping.
pub fn htmlEscape(out: anytype, text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const replacement: ?[]const u8 = switch (text[i]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try out.writeAll(text[start..i]);
            try out.writeAll(r);
            start = i + 1;
        }
    }
    if (start < text.len) try out.writeAll(text[start..]);
}

// ---------------------------------------------------------------------------
// Tests (filesystem-free, pure bytes in → bytes out).
// ---------------------------------------------------------------------------

const testing = std.testing;

const full_meta =
    \\
    \\{"title":"Hi","description":"A page","author":"Bob","date":"2026-01-01","palette":"dark","template":"","render_profile":""}
;
const empty_meta =
    \\
    \\{"title":"","description":"","author":"","date":"","palette":"","template":"","render_profile":""}
;

fn wrapT(template: []const u8, meta_json: []const u8, body: []const u8, assets_root: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer aw.deinit();
    try wrap(testing.allocator, meta_json, template, body, assets_root, &aw.writer);
    return try aw.toOwnedSlice();
}

// --- basic substitution ---

test "wrap: basic token substitution" {
    const template = "T:$title$ D:$description$";
    const out = try wrapT(template, full_meta, "", "./assets/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("T:Hi D:A page", out);
}

test "wrap: all 5 meta tokens" {
    const template = "$title$|$description$|$author$|$date$|$palette$";
    const out = try wrapT(template, full_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hi|A page|Bob|2026-01-01|dark", out);
}

test "wrap: assets_root and body are literal (unescaped)" {
    const template = "assets:$assets_root$ body:$body$";
    const out = try wrapT(template, empty_meta, "<h1>Body</h1>", "../../assets/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("assets:../../assets/ body:<h1>Body</h1>", out);
}

test "wrap: unknown tokens pass verbatim" {
    const template = "$unknown$ and $also_unknown$";
    const out = try wrapT(template, empty_meta, "", "./");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("$unknown$ and $also_unknown$", out);
}

// --- html escaping ---

test "wrap: html escaping of meta fields" {
    const meta_json =
        \\{"title":"Cats & Dogs <v0.5.1>","description":"\"quoted\"","author":"O'Brien","date":"","palette":"","template":"","render_profile":""}
    ;
    const template = "$title$ $description$ $author$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Cats &amp; Dogs &lt;v0.5.1&gt; &quot;quoted&quot; O&#39;Brien", out);
}

test "wrap: html escaping escapes & first (no double-escape)" {
    const meta_json =
        \\{"title":"A &amp; B","description":"","author":"","date":"","palette":"","template":"","render_profile":""}
    ;
    const template = "$title$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    // JSON decoded: literal "A &amp; B". The & is escaped → "A &amp;amp; B".
    try testing.expectEqualStrings("A &amp;amp; B", out);
}

test "wrap: empty meta fields become empty strings" {
    const template = "[$title$][$description$]";
    const out = try wrapT(template, empty_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[][]", out);
}

// --- $if$ blocks ---

test "wrap: $if(title)$ keeps interior when non-empty" {
    const template = "TITLE:$if(title)$[$title$]$endif$";
    const out = try wrapT(template, full_meta, "", "");
    defer testing.allocator.free(out);
    // stripIfs: title is "Hi" → keep interior "[$title$]$" → wait, interior
    // is between after_if_close and end. The interior includes the trailing
    // content up to $endif$. After stripIfs we have "[$title$]", then
    // substitute replaces $title$ with "Hi".
    try testing.expectEqualStrings("TITLE:[Hi]", out);
}

test "wrap: $if(title)$ removes block when empty" {
    const template = "TITLE:$if(title)$KEEP$endif$";
    const out = try wrapT(template, empty_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("TITLE:", out);
}

test "wrap: $if$ with empty and non-empty fields mixed" {
    const template = "$if(title)$T:$title$ $endif$$if(author)$A:$author$ $endif$$if(date)$D:$date$$endif$";
    const out = try wrapT(template, full_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("T:Hi A:Bob D:2026-01-01", out);
}

test "wrap: $if$ with mixed empty/non-empty" {
    const meta_json =
        \\{"title":"","description":"has desc","author":"","date":"2026","palette":"","template":"","render_profile":""}
    ;
    const template = "T:$if(title)$[$title$]$endif$ D:$if(description)$[$description$]$endif$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    // title empty → block removed; description non-empty → kept.
    try testing.expectEqualStrings("T: D:[has desc]", out);
}

test "wrap: first $endif$ closes (no nesting)" {
    const template = "$if(title)$X$endif$Y$endif$";
    const out = try wrapT(template, full_meta, "", "");
    defer testing.allocator.free(out);
    // stripIfs: first $endif$ closes → interior is "X".
    // The second "$endif$" passes to substitute as unknown token.
    try testing.expectEqualStrings("XY$endif$", out);
}

test "wrap: unknown $if$ name passes verbatim" {
    const template = "$if(unknown)$KEEP$endif$ $if(title)$OK$endif$";
    const out = try wrapT(template, full_meta, "", "");
    defer testing.allocator.free(out);
    // Unknown name: verbatim passthrough.
    // title "Hi" → keep interior "OK".
    try testing.expectEqualStrings("$if(unknown)$KEEP$endif$ OK", out);
}

test "wrap: $if$ with multiline interior" {
    const meta_json =
        \\{"title":"X","description":"","author":"","date":"","palette":"","template":"","render_profile":""}
    ;
    const template = "$if(title)$line1\nline2\n$endif$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("line1\nline2\n", out);
}

test "wrap: $if$ removes entire block including interior newlines when empty" {
    const template = "BEFORE$if(title)$line1\nline2\n$endif$AFTER";
    const out = try wrapT(template, empty_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("BEFOREAFTER", out);
}

// --- combined: $if$ + substitution ---

test "wrap: custom template with $if$, $title$, $assets_root$, $body$" {
    const template =
        \\<title>$if(title)$[$title$]$endif$</title>
        \\<link rel="stylesheet" href="$assets_root$style.css" />
        \\<div id="content">$body$</div>
        \\
    ;
    const out = try wrapT(template, full_meta, "<p>Hello</p>", "./assets/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\<title>[Hi]</title>
        \\<link rel="stylesheet" href="./assets/style.css" />
        \\<div id="content"><p>Hello</p></div>
        \\
    , out);
}

test "wrap: empty-title removal with surrounding content" {
    const template = "BEFORE:$if(title)$TITLE:$title$:$endif$:AFTER";
    const out = try wrapT(template, empty_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("BEFORE::AFTER", out);
}

test "wrap: $body$ empty produces empty slot" {
    const template = "<div>$body$</div>";
    const out = try wrapT(template, empty_meta, "", "./");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<div></div>", out);
}

// --- htmlEscape unit tests ---

test "htmlEscape: no special chars passes through" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try htmlEscape(&aw.writer, "hello world 123");
    try testing.expectEqualStrings("hello world 123", aw.written());
}

test "htmlEscape: all five special chars" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try htmlEscape(&aw.writer, "a&b<c>d\"e'f");
    try testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&#39;f", aw.written());
}

test "htmlEscape: empty string" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try htmlEscape(&aw.writer, "");
    try testing.expectEqualStrings("", aw.written());
}
