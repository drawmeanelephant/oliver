//! HTML 4.01 Strict profile: paired output, fail-closed behavior and a
//! hermetic vocabulary/content-model gate on complete test documents.
const std = @import("std");
const oliver = @import("oliver");
const valid = @import("html4_strict_valid.zig");
const a = std.testing.allocator;

fn document(input: []const u8, dialect: oliver.Dialect, parse_options: oliver.ParseOptions, render_options: oliver.html.RenderOptions) !std.ArrayList(u8) {
    var result = try oliver.parse(a, input, dialect, parse_options);
    defer result.deinit();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try oliver.html.render(a, &writer.writer, &result.document, render_options);
    return writer.toArrayList();
}

fn recipe(input: []const u8, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(a, input, .{});
    defer result.deinit();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try oliver.cooklang_html.render(a, &writer.writer, &result.recipe, .{ .profile = profile });
    return writer.toArrayList();
}

fn check(fragment: []const u8) !void {
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(a);
    // The wrapper is test-only; renderers continue to return fragments.
    try wrapped.appendSlice(a, "<html><head><title>Oliver</title></head><body>");
    try wrapped.appendSlice(a, fragment);
    try wrapped.appendSlice(a, "</body></html>");
    try valid.check(wrapped.items);
}

test "html4 strict: unchanged structures agree with HTML, across frontends" {
    const cases = .{
        .{ oliver.Dialect.markdown, "# Heading\n\nText with *emphasis* and [link](/a).\n\n| H | R |\n| :- | -: |\n| x | y |\n" },
        .{ oliver.Dialect.textile, "h2(title#item)[en]. Heading\n\np{color:red;}. A %(foo)span% and *bold*.\n\n|_. H |_. R |\n| x | y |\n" },
    };
    inline for (cases) |case| {
        var html = try document(case[1], case[0], .{}, .{});
        defer html.deinit(a);
        var strict = try document(case[1], case[0], .{}, .{ .profile = .html4_strict });
        defer strict.deinit(a);
        try std.testing.expectEqualSlices(u8, html.items, strict.items);
        try check(strict.items);
    }
}

test "html4 strict: extension vocabulary and footnote accessibility fallback" {
    const source =
        \\# Good heading
        \\
        \\See [[Page|label]], ~~deleted~~, and "quotes" with note[^a] twice[^a].
        \\
        \\> [!note] Title
        \\> Body.
        \\
        \\- [x] done
        \\
        \\Term
        \\: definition
        \\
        \\[^a]: Footnote text.
        \\
    ;
    const parse_opts = oliver.ParseOptions{ .markdown = .{
        .footnotes = true,
        .definition_lists = true,
        .strikethrough = true,
        .wikilinks = true,
        .callouts = true,
        .smartypants = true,
        .task_lists = true,
        .heading_attributes = true,
    } };
    var strict = try document(source, .markdown, parse_opts, .{ .profile = .html4_strict, .footnotes = true, .heading_ids = true });
    defer strict.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "<div class=\"footnotes\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "title=\"Back to reference 1-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "disabled=\"disabled\" checked=\"checked\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "data-") == null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "aria-") == null);
    try check(strict.items);
}

test "html4 strict: Cooklang sectioning, timers and data attrs are mapped" {
    const source = "= Dough\n\nMix @flour{200%g} with @./other/Recipe{1} in #pan{2} for ~{25%minutes} \\\nand rest.\n\n> Note here.\n\n== Filling ==\nStir @salt.\n";
    var html = try recipe(source, .html);
    defer html.deinit(a);
    var strict = try recipe(source, .html4_strict);
    defer strict.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, html.items, "<article") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "<div class=\"recipe\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "<span class=\"timer\">25 minutes</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "data-") == null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "datetime=") == null);
    try std.testing.expect(std.mem.indexOf(u8, strict.items, "<section") == null);
    try check(strict.items);
    var again = try recipe(source, .html4_strict);
    defer again.deinit(a);
    try std.testing.expectEqualSlices(u8, strict.items, again.items);
}

test "html4 strict: reject verbatim and non-default list starts, allow escaped text" {
    const raw = [_]struct { oliver.Dialect, []const u8 }{
        .{ .markdown, "before <b>raw</b> after\n" },
        .{ .markdown, "<div>\nraw\n</div>\n" },
        .{ .textile, "pre. <b>verbatim</b>\n" },
        .{ .textile, "notextile. <span>raw</span>\n" },
    };
    for (raw) |case| {
        try std.testing.expectError(error.RawHtmlNotHtml4Strict, document(case[1], case[0], .{}, .{ .profile = .html4_strict }));
        var escaped = try document(case[1], case[0], .{}, .{ .profile = .html4_strict, .raw_html = .escaped });
        defer escaped.deinit(a);
        try check(escaped.items);
    }
    try std.testing.expectError(error.OrderedListStartNotHtml4Strict, document("3. third\n", .markdown, .{}, .{ .profile = .html4_strict }));
    try std.testing.expectError(error.InvalidHtml4StrictId, document("# 123 heading\n", .markdown, .{}, .{ .profile = .html4_strict, .heading_ids = true }));
    try std.testing.expectError(error.InvalidHtml4StrictId, document("h1(#123). Heading\n", .textile, .{}, .{ .profile = .html4_strict }));
    try std.testing.expectError(error.DuplicateHtml4StrictId, document("# Same\n\n# Same\n", .markdown, .{}, .{ .profile = .html4_strict, .heading_ids = true }));
    try std.testing.expectError(error.DuplicateHtml4StrictId, document("# Heading {#fnref-1}\n\nNote[^a].\n\n[^a]: Body.\n", .markdown, .{ .markdown = .{ .footnotes = true, .heading_attributes = true } }, .{ .profile = .html4_strict, .footnotes = true }));
    var original = try document("3. third\n", .markdown, .{}, .{});
    defer original.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, original.items, "start=\"3\"") != null);
}
