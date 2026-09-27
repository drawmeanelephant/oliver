//! Test-only checker for the HTML 4.01 Strict subset Oliver emits.
//! Not an SGML parser or an independent implementation of the full DTD.
//! The DTD is SGML (not XML), so xmllint cannot validate it. This gate
//! checks the emitted vocabulary, attribute sets, selected nesting rules,
//! and the table body's required cardinality without external tools.
const std = @import("std");

pub const Error = error{Invalid};

const empty = "br hr img input";
const blocks = "p h1 h2 h3 h4 h5 h6 pre blockquote div ul ol dl table hr";
const inline_tags = "a em strong b i del ins big small sup sub cite span code acronym br img input";
const table_parts = "caption col colgroup thead tfoot tbody tr";
const cells = "th td";
const global = "id class style title lang dir";

fn member(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

fn allowedChild(parent: []const u8, child: []const u8) bool {
    if (member("html", parent)) return member("head body", child);
    if (member("head", parent)) return member("title", child);
    if (member("body div li dd blockquote", parent)) return member(blocks, child) or member(inline_tags, child);
    if (member("a", parent)) return member(inline_tags, child) and !member("a", child);
    if (member("p h1 h2 h3 h4 h5 h6 dt em strong b i del ins big small sup sub cite span code acronym th td title", parent))
        return member(inline_tags, child);
    if (member("ul ol", parent)) return member("li", child);
    if (member("dl", parent)) return member("dt dd", child);
    if (member("table", parent)) return member("caption col colgroup thead tfoot tbody", child);
    if (member("thead tbody tfoot", parent)) return member("tr", child);
    if (member("tr", parent)) return member(cells, child);
    if (member("pre", parent)) return member(inline_tags, child) and !member("img input big small sup sub", child);
    return false;
}

fn allowedAttr(tag: []const u8, attr: []const u8) bool {
    if (member(global, attr)) return true;
    if (member("a", tag)) return member("href name rel rev charset hreflang type accesskey tabindex", attr);
    if (member("blockquote", tag)) return member("cite", attr);
    if (member("img", tag)) return member("src alt longdesc height width usemap ismap", attr);
    if (member("input", tag)) return member("type name value checked disabled readonly size maxlength src alt usemap tabindex accesskey", attr);
    if (member("th td", tag)) return member("abbr axis headers scope rowspan colspan align char charoff valign", attr);
    if (member("tr thead tbody tfoot col colgroup", tag)) return member("align char charoff valign span width", attr);
    if (member("table", tag)) return member("summary width border frame rules cellspacing cellpadding", attr);
    return false;
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and !memberChar("-_.:", c)) return false;
    }
    return true;
}

fn memberChar(chars: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, chars, c) != null;
}

fn validAttrValue(name: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, name, "id")) return validId(value);
    if (member("disabled checked readonly", name)) return std.mem.eql(u8, name, value);
    if (std.mem.eql(u8, name, "align")) return member("left center right justify char", value);
    if (member("rowspan colspan", name)) {
        if (value.len == 0) return false;
        for (value) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn space(c: u8) bool {
    return memberChar(" \n\r\t", c);
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or memberChar("-_:", c);
}

fn scanName(bytes: []const u8, pos: *usize) Error![]const u8 {
    const start = pos.*;
    while (pos.* < bytes.len and nameChar(bytes[pos.*])) pos.* += 1;
    if (pos.* == start) return error.Invalid;
    return bytes[start..pos.*];
}

fn skipSpace(bytes: []const u8, pos: *usize) void {
    while (pos.* < bytes.len and space(bytes[pos.*])) pos.* += 1;
}

fn reference(bytes: []const u8, pos: *usize) Error!void {
    const rest = bytes[pos.*..];
    for ([_][]const u8{ "&amp;", "&lt;", "&gt;", "&quot;" }) |entity| {
        if (std.mem.startsWith(u8, rest, entity)) {
            pos.* += entity.len;
            return;
        }
    }
    return error.Invalid;
}

/// Check a complete minimal document (the caller wraps rendered fragments).
pub fn check(bytes: []const u8) Error!void {
    const Frame = struct {
        name: []const u8,
        tbody_count: usize = 0,
        row_count: usize = 0,
    };
    var stack: [256]Frame = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    var root_seen = false;
    while (pos < bytes.len) {
        if (bytes[pos] != '<') {
            if (bytes[pos] == '&') {
                try reference(bytes, &pos);
            } else {
                if (bytes[pos] < 0x20 and !space(bytes[pos])) return error.Invalid;
                pos += 1;
            }
            continue;
        }
        pos += 1;
        if (pos >= bytes.len) return error.Invalid;
        if (bytes[pos] == '/') {
            pos += 1;
            const tag = try scanName(bytes, &pos);
            skipSpace(bytes, &pos);
            if (pos >= bytes.len or bytes[pos] != '>' or depth == 0) return error.Invalid;
            pos += 1;
            depth -= 1;
            const frame = stack[depth];
            if (!std.mem.eql(u8, frame.name, tag)) return error.Invalid;
            if (member("table", tag) and frame.tbody_count == 0) return error.Invalid;
            if (member("tbody", tag) and frame.row_count == 0) return error.Invalid;
            continue;
        }
        const tag = try scanName(bytes, &pos);
        if (!member(blocks, tag) and !member(inline_tags, tag) and
            !member(table_parts, tag) and !member(cells, tag) and
            !member("html head body title li dt dd", tag)) return error.Invalid;
        if (depth == 0) {
            if (root_seen or !std.mem.eql(u8, tag, "html")) return error.Invalid;
            root_seen = true;
        } else {
            const parent = &stack[depth - 1];
            if (!allowedChild(parent.name, tag)) return error.Invalid;
            if (member("table", parent.name) and member("tbody", tag)) parent.tbody_count += 1;
            if (member("tbody", parent.name) and member("tr", tag)) parent.row_count += 1;
        }

        while (true) {
            const before_ws = pos;
            skipSpace(bytes, &pos);
            if (pos == bytes.len) return error.Invalid;
            if (bytes[pos] == '>') {
                pos += 1;
                break;
            }
            if (pos == before_ws) return error.Invalid;
            const attr = try scanName(bytes, &pos);
            if (!allowedAttr(tag, attr)) return error.Invalid;
            skipSpace(bytes, &pos);
            if (pos >= bytes.len or bytes[pos] != '=') return error.Invalid;
            pos += 1;
            skipSpace(bytes, &pos);
            if (pos >= bytes.len or bytes[pos] != '"') return error.Invalid;
            pos += 1;
            const start = pos;
            while (pos < bytes.len and bytes[pos] != '"') {
                if (bytes[pos] == '<') return error.Invalid;
                if (bytes[pos] == '&') {
                    try reference(bytes, &pos);
                } else pos += 1;
            }
            if (pos == bytes.len or !validAttrValue(attr, bytes[start..pos])) return error.Invalid;
            pos += 1;
        }
        if (!member(empty, tag)) {
            if (depth == stack.len) return error.Invalid;
            stack[depth] = .{ .name = tag };
            depth += 1;
        }
    }
    if (!root_seen or depth != 0 or !std.mem.endsWith(u8, bytes, "</html>")) return error.Invalid;
}

test "checker rejects elements, attributes, content and tokens outside Strict" {
    const prefix = "<html><head><title>Oliver</title></head><body>";
    const suffix = "</body></html>";
    try check(prefix ++ "<p>hello &amp; <strong>world</strong><br></p>" ++ suffix);
    try check(prefix ++ "<table><tbody><tr><th>H</th></tr></tbody></table>" ++ suffix);
    for ([_][]const u8{
        "<article>x</article>",               "<p data-x=\"1\">x</p>",
        "<ol start=\"3\"><li>x</li></ol>",    "<p><div>x</div></p>",
        "<ul><p>x</p></ul>",                  "<input type=\"checkbox\" disabled=\"\">",
        "<p id=\"3bad\">x</p>",               "<p>bad &bogus;</p>",
        "<table><tr><td>x</td></tr></table>", "<table><thead><tr><th>H</th></tr></thead></table>",
        "<table><tbody></tbody></table>",     "<p><a href=\"/a\"><a href=\"/b\">nested</a></a></p>",
    }) |fragment| {
        // The test supplies the same minimal wrapper as the gate.
        var bytes: [512]u8 = undefined;
        const doc = std.fmt.bufPrint(&bytes, "{s}{s}{s}", .{ prefix, fragment, suffix }) catch unreachable;
        try std.testing.expectError(error.Invalid, check(doc));
    }
}
