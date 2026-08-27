//! Phase 6 S2 — template dialect for `oliver wrap`.
//!
//! Implements the shared template contract v2 (`oliver-contract.md`
//! §Template and input contract, rotkeeper #244): the original 7 tokens
//! plus the extended metadata tokens:
//!
//!   $title$ $description$ $author$ $date$ $palette$
//!   $version$ $subtitle$ $tags$ $asset_meta$
//!   $navigation$ $warnings$                            → html_escape
//!   $assets_root$ $body$                              → literal
//!
//! Conditional blocks: `$if(name)$...$endif$` for every meta field
//! (first `$endif$` closes, no nesting, verbatim unknown). Empty/null →
//! block removed; absent known field → empty; all `$if$` resolved before
//! literal subs.
//!
//! v3 generic hook (rotkeeper #269): **any key present in `--meta-json`
//! beyond the typed set becomes an interpolatable token** — no upstream
//! rebuild needed to add a frontmatter field. String values substitute
//! html-escaped; null → empty; other scalars stringify; objects/arrays
//! render as compact JSON. `$if$` gating extends to every present key;
//! keys absent from meta-json still pass through verbatim.
//!
//! The library stays filesystem-free; this is pure bytes in → bytes out.

const std = @import("std");

/// The JSON wire type for the typed meta fields. Unknown fields are
/// silently ignored (the S1 contract also ships `template` and
/// `render_profile` which we don't need here). The extended v2 keys
/// (version, subtitle, tags, asset_meta, navigation, warnings) are
/// scalars the adapter feeds from bones/config/version and the source
/// frontmatter. Any other key is handled generically via `extras` (v3).
const MetaJson = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    palette: ?[]const u8 = null,
    version: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    asset_meta: ?[]const u8 = null,
    navigation: ?[]const u8 = null,
    warnings: ?[]const u8 = null,
};

/// The resolved meta for template interpolation. `value` holds the typed
/// v1/v2 fields; `extras` borrows the full object map from the dynamic
/// parse so any other key is interpolatable (v3 generic hook). `scratch`
/// is an arena for stringified non-string extras; the caller keeps the
/// underlying parses and arena alive while accessing fields.
pub const ParsedMeta = struct {
    value: MetaJson = .{},
    extras: std.json.ObjectMap = .{},
    scratch: std.mem.Allocator,
};

/// Resolves a field name to its value (for `$if$` lookup and substitution).
/// Returns empty string for missing/null fields (the contract
/// guarantees all keys, but being defensive is free). Typed v1/v2 fields
/// resolve first; then the v3 generic extras map — any present key.
fn fieldVal(a: std.mem.Allocator, m: ParsedMeta, name: []const u8) ![]const u8 {
    const v = m.value;
    if (std.mem.eql(u8, name, "title")) return v.title orelse "";
    if (std.mem.eql(u8, name, "description")) return v.description orelse "";
    if (std.mem.eql(u8, name, "author")) return v.author orelse "";
    if (std.mem.eql(u8, name, "date")) return v.date orelse "";
    if (std.mem.eql(u8, name, "palette")) return v.palette orelse "";
    if (std.mem.eql(u8, name, "version")) return v.version orelse "";
    if (std.mem.eql(u8, name, "subtitle")) return v.subtitle orelse "";
    if (std.mem.eql(u8, name, "tags")) return v.tags orelse "";
    if (std.mem.eql(u8, name, "asset_meta")) return v.asset_meta orelse "";
    if (std.mem.eql(u8, name, "navigation")) return v.navigation orelse "";
    if (std.mem.eql(u8, name, "warnings")) return v.warnings orelse "";
    if (m.extras.get(name)) |val| return try extraString(a, m, val);
    return "";
}

/// Renders an extras value as text: strings as-is, null → empty, other
/// scalars stringified, objects/arrays as compact JSON. Non-string
/// results are duplicated into the scratch arena.
fn extraString(a: std.mem.Allocator, m: ParsedMeta, val: std.json.Value) ![]const u8 {
    return switch (val) {
        .null => "",
        .string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(m.scratch, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(m.scratch, "{d}", .{f}),
        .number_string => |s| s,
        .array, .object => blk: {
            var aw = std.Io.Writer.Allocating.init(a);
            defer aw.deinit();
            try std.json.Stringify.value(val, .{}, &aw.writer);
            break :blk try m.scratch.dupe(u8, aw.written());
        },
    };
}

/// Whether the given name is a recognized meta field with a non-empty value.
fn isNonEmpty(a: std.mem.Allocator, m: ParsedMeta, name: []const u8) !bool {
    return (try fieldVal(a, m, name)).len > 0;
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
    // Parse the meta JSON twice: a typed parse for the v1/v2 fields
    // (string/null, unknown keys ignored) and a dynamic parse for the
    // v3 extras map (any key, any JSON type). Both arenas stay alive
    // through interpolation; the scratch arena owns stringified extras.
    var typed = std.json.parseFromSlice(MetaJson, a, meta_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MetaJsonParseError;
    defer typed.deinit();

    var root = std.json.parseFromSlice(std.json.Value, a, meta_json, .{}) catch return error.MetaJsonParseError;
    defer root.deinit();
    if (root.value != .object) return error.MetaJsonParseError;

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();

    const meta = ParsedMeta{
        .value = typed.value,
        .extras = root.value.object,
        .scratch = scratch.allocator(),
    };

    // Phase 1: strip $if(name)$...$endif$ blocks.
    const stripped = try stripIfs(a, template, meta);
    defer a.free(stripped);

    // Phase 2: substitute the literal tokens.
    try substitute(a, stripped, meta, body, assets_root, out);
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
        if (!isKnownField(m, name)) {
            try out.appendSlice(a, template[fs..after_endif]);
        } else if (try isNonEmpty(a, m, name)) {
            try out.appendSlice(a, interior);
        }
        // else: known field but empty → block removed (skip).

        i = after_endif;
    }
    return out.toOwnedSlice(a);
}

/// Whether `name` is one of the typed meta fields (v1 five + v2 extended
/// set) or present in the v3 extras map.
fn isKnownField(m: ParsedMeta, name: []const u8) bool {
    return typedKnownField(name) or m.extras.contains(name);
}

/// Whether `name` is one of the typed v1/v2 meta fields.
fn typedKnownField(name: []const u8) bool {
    return std.mem.eql(u8, name, "title") or
        std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "author") or
        std.mem.eql(u8, name, "date") or
        std.mem.eql(u8, name, "palette") or
        std.mem.eql(u8, name, "version") or
        std.mem.eql(u8, name, "subtitle") or
        std.mem.eql(u8, name, "tags") or
        std.mem.eql(u8, name, "asset_meta") or
        std.mem.eql(u8, name, "navigation") or
        std.mem.eql(u8, name, "warnings");
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

/// Substitutes the recognized tokens: html-escaped meta fields
/// (v1 five + v2 extended set), plus `$assets_root$` and `$body$` as
/// literals. Unknown `$word$` passes verbatim.
fn substitute(
    a: std.mem.Allocator,
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
        } else if (isKnownField(m, name)) {
            try htmlEscape(out, try fieldVal(a, m, name));
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

// --- v2 extended tokens (rotkeeper #244 shared template contract) ---

const v2_meta =
    \\
    \\{"title":"T","description":"D","author":"","date":"","palette":"","version":"0.7.0","subtitle":"Sub & Title","tags":"a, b","asset_meta":"index.md — Filed Systems","navigation":"","warnings":""}
;

test "wrap: v2 extended tokens substitute (escaped)" {
    const template = "v:$version$|sub:$subtitle$|tags:$tags$|am:$asset_meta$";
    const out = try wrapT(template, v2_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("v:0.7.0|sub:Sub &amp; Title|tags:a, b|am:index.md — Filed Systems", out);
}

test "wrap: v2 token html escaping" {
    const meta_json =
        \\{"title":"","description":"","author":"","date":"","palette":"","version":"<0.7.0 & beta>","subtitle":"","tags":"","asset_meta":"","navigation":"","warnings":""}
    ;
    const template = "$version$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;0.7.0 &amp; beta&gt;", out);
}

test "wrap: v2 absent known token substitutes empty" {
    // empty_meta carries no v2 keys; known-but-absent → empty string.
    const template = "[$version$][$tags$][$asset_meta$]";
    const out = try wrapT(template, empty_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[][][]", out);
}

test "wrap: v2 $if$ gating keeps non-empty" {
    const template = "V:$if(version)$[$version$]$endif$ T:$if(tags)$[$tags$]$endif$";
    const out = try wrapT(template, v2_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("V:[0.7.0] T:[a, b]", out);
}

test "wrap: v2 $if$ gating removes empty/absent" {
    const template = "V:$if(version)$X$endif$ N:$if(navigation)$X$endif$ W:$if(warnings)$X$endif$";
    const out = try wrapT(template, v2_meta, "", "");
    defer testing.allocator.free(out);
    // version non-empty → kept; navigation/warnings present-but-empty → removed.
    try testing.expectEqualStrings("V:X N: W:", out);
}

// --- v3 generic hook (rotkeeper #269 reusable frontmatter injection) ---

const generic_meta =
    \\{"title":"T","description":"","author":"","date":"","palette":"","version":"","subtitle":"","tags":"","asset_meta":"","navigation":"","warnings":"","page_type":"404","slug":"/tomb","count":7,"draft":false,"nested":{"a":1},"evil":"<x & y>"}
;

test "wrap: v3 any meta-json key substitutes (no upstream change needed)" {
    const template = "pt:$page_type$|slug:$slug$";
    const out = try wrapT(template, generic_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("pt:404|slug:/tomb", out);
}

test "wrap: v3 non-string extras stringify (escaped like every token)" {
    const template = "c:$count$|d:$draft$|n:$nested$";
    const out = try wrapT(template, generic_meta, "", "");
    defer testing.allocator.free(out);
    // Scalars stringify plainly; the nested object renders as compact JSON,
    // then html-escaped like any other token (renders as {"a":1} in HTML).
    try testing.expectEqualStrings("c:7|d:false|n:{&quot;a&quot;:1}", out);
}

test "wrap: v3 extras html-escaped" {
    const template = "$evil$";
    const out = try wrapT(template, generic_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;x &amp; y&gt;", out);
}

test "wrap: v3 $if$ gating on generic keys" {
    const template = "P:$if(page_type)$[$page_type$]$endif$ M:$if(missing_key)$X$endif$";
    const out = try wrapT(template, generic_meta, "", "");
    defer testing.allocator.free(out);
    // page_type present+non-empty → kept; missing_key absent → verbatim.
    try testing.expectEqualStrings("P:[404] M:$if(missing_key)$X$endif$", out);
}

test "wrap: v3 absent key passes verbatim" {
    const template = "A:$missing_key$";
    const out = try wrapT(template, generic_meta, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A:$missing_key$", out);
}

test "wrap: v3 generic key with null value gates off" {
    const meta_json =
        \\{"title":"","description":"","author":"","date":"","palette":"","version":"","subtitle":"","tags":"","asset_meta":"","navigation":"","warnings":"","page_type":null}
    ;
    const template = "X:$if(page_type)$[$page_type$]$endif$";
    const out = try wrapT(template, meta_json, "", "");
    defer testing.allocator.free(out);
    // null → empty → block removed.
    try testing.expectEqualStrings("X:", out);
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
