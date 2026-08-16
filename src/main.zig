//! Provisional CLI: a thin adapter over the library for shell integration.
//!
//!     oliver render    --from markdown [--to html|xhtml] < document.md
//!     oliver render    --from textile  [--to html|xhtml] < document.textile
//!     oliver render    --from cooklang [--to html|xhtml] < recipe.cook
//!     oliver serialize --from cooklang < recipe.cook > canonical.cook
//!     oliver scale --from cooklang --factor 2 < recipe.cook > doubled.cook
//!     oliver scale --from cooklang --factor 3/2 < recipe.cook
//!     oliver scale --from cooklang --servings 4 < recipe.cook
//!     oliver menu --from cooklang < plan.menu   # day/meal text dump
//!
//! All parser and renderer semantics live in the library; this file only
//! handles arguments and stdio. It uses the Zig 0.16 `std.process.Init`
//! entry point for a ready allocator and `Io` instance.

const std = @import("std");
const oliver = @import("oliver");
// Injected by build.zig: the package version and the source commit SHA
// (CI passes -Dcommit=$GITHUB_SHA). `oliver --version` prints them so a
// downloaded binary can prove which commit it was built from.
const build_options = @import("build_options");

/// The CLI operation, selected by the subcommand token. Exactly one is
/// required; `parseArgs` rejects a missing, duplicated, or conflicting
/// subcommand (issue #57).
pub const Command = enum {
    render,
    serialize,
    scale,
    menu,
};

/// The full command-line configuration, decided by `parseArgs`. `command`
/// selects the operation; `dialect`/`cooklang` name the input frontend;
/// `factor`/`servings` configure scaling; `profile` selects the renderer
/// serialization (`html` by default, `xhtml` with `--to xhtml`).
pub const RunConfig = struct {
    command: Command,
    dialect: ?oliver.Dialect = null,
    cooklang: bool = false,
    factor_num: ?u32 = null,
    factor_den: ?u32 = null,
    servings_target: ?u32 = null,
    profile: oliver.OutputProfile = .html,
    /// Markdown extension surface (`render --from markdown` only; all off
    /// by default). `parseArgs` scopes them to the Markdown frontend;
    /// `markdownParseOptions` / `renderOptionsFor` thread them into
    /// `markdown.Options` and the footnotes / heading-ids render options
    /// (docs/MARKDOWN-EXTENSIONS.md).
    footnotes: bool = false,
    definition_lists: bool = false,
    heading_attributes: bool = false,
    strikethrough: bool = false,
    wikilinks: bool = false,
    callouts: bool = false,
    smartypants: bool = false,
    heading_ids: bool = false,
    /// Front matter mode (`render` with any frontend; null = default
    /// off). Shared by all three frontends (docs/FRONTMATTER.md §3).
    frontmatter: ?oliver.frontmatter.Option = null,
};

/// Parses the argument vector (excluding the program name) into a
/// `RunConfig`. Returns `error.Usage` for any unknown flag, invalid value,
/// missing or duplicated subcommand, or flag that does not belong to the
/// selected command (`--to` is render-only; `--factor`/`--servings` are
/// scale-only), and `error.Help` for `--help`/`-h` (help is a requested
/// outcome, not an error). Pure: no allocator, no I/O, so it is
/// unit-tested directly.
pub fn parseArgs(args: []const []const u8) error{ Usage, Help, Version }!RunConfig {
    var command: ?Command = null;
    var dialect: ?oliver.Dialect = null;
    var cooklang = false;
    var factor_num: ?u32 = null;
    var factor_den: ?u32 = null;
    var servings_target: ?u32 = null;
    var profile: oliver.OutputProfile = .html;
    var footnotes = false;
    var definition_lists = false;
    var heading_attributes = false;
    var strikethrough = false;
    var wikilinks = false;
    var callouts = false;
    var smartypants = false;
    var heading_ids = false;
    var frontmatter: ?oliver.frontmatter.Option = null;
    var saw_to = false;
    var saw_from = false;
    var saw_frontmatter = false;
    var saw_factor = false;
    var saw_servings = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "render")) {
            if (command != null) return error.Usage;
            command = .render;
        } else if (std.mem.eql(u8, arg, "serialize")) {
            if (command != null) return error.Usage;
            command = .serialize;
        } else if (std.mem.eql(u8, arg, "scale")) {
            if (command != null) return error.Usage;
            command = .scale;
        } else if (std.mem.eql(u8, arg, "menu")) {
            if (command != null) return error.Usage;
            command = .menu;
        } else if (std.mem.eql(u8, arg, "--from")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            // A second `--from` would contradict the first (e.g. both
            // `markdown` and `cooklang`), so reject duplicates instead
            // of silently letting the last one win.
            if (saw_from) return error.Usage;
            saw_from = true;
            const value = args[index];
            if (std.mem.eql(u8, value, "markdown")) {
                dialect = .markdown;
            } else if (std.mem.eql(u8, value, "textile")) {
                dialect = .textile;
            } else if (std.mem.eql(u8, value, "cooklang")) {
                cooklang = true;
            } else return error.Usage;
        } else if (std.mem.eql(u8, arg, "--to")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            if (std.mem.eql(u8, value, "html")) {
                profile = .html;
            } else if (std.mem.eql(u8, value, "xhtml")) {
                profile = .xhtml;
            } else return error.Usage;
            saw_to = true;
        } else if (std.mem.eql(u8, arg, "--factor")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            // A second `--factor` would contradict the first; reject
            // duplicates like `--from`/`--to`/`--frontmatter`.
            if (saw_factor) return error.Usage;
            saw_factor = true;
            const value = args[index];
            // The library's parseFactor owns the grammar: the same
            // scalable forms as amounts (integer, a/b, decimal, mixed
            // `1 1/2`; spaces around the slash accepted) and the u32 cap
            // that matches ScaleBy.factor. Zero numerators and zero
            // denominators are rejected by parseFactor itself
            // (docs/COOKLANG.md §11); InvalidScaleFactor maps to a usage
            // error.
            const f = oliver.cooklang_scale.parseFactor(value) catch return error.Usage;
            factor_num = @intCast(f.num);
            factor_den = @intCast(f.den);
        } else if (std.mem.eql(u8, arg, "--servings")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            // Duplicate servings contradict each other; reject them like
            // every other value flag.
            if (saw_servings) return error.Usage;
            saw_servings = true;
            const value = args[index];
            servings_target = std.fmt.parseUnsigned(u32, value, 10) catch return error.Usage;
            if (servings_target.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--wikilinks")) {
            wikilinks = true;
        } else if (std.mem.eql(u8, arg, "--callouts")) {
            callouts = true;
        } else if (std.mem.eql(u8, arg, "--smartypants")) {
            smartypants = true;
        } else if (std.mem.eql(u8, arg, "--footnotes")) {
            footnotes = true;
        } else if (std.mem.eql(u8, arg, "--definition-lists")) {
            definition_lists = true;
        } else if (std.mem.eql(u8, arg, "--heading-attributes")) {
            heading_attributes = true;
        } else if (std.mem.eql(u8, arg, "--strikethrough")) {
            strikethrough = true;
        } else if (std.mem.eql(u8, arg, "--heading-ids")) {
            heading_ids = true;
        } else if (std.mem.eql(u8, arg, "--frontmatter")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            // A second `--frontmatter` would contradict the first (like
            // a second `--from`), so reject duplicates.
            if (saw_frontmatter) return error.Usage;
            saw_frontmatter = true;
            const value = args[index];
            if (std.mem.eql(u8, value, "yaml")) {
                frontmatter = .yaml;
            } else if (std.mem.eql(u8, value, "toml")) {
                frontmatter = .toml;
            } else return error.Usage;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return error.Version;
        } else return error.Usage;
    }

    // Exactly one subcommand names the operation, and every command
    // needs an input frontend.
    const cmd = command orelse return error.Usage;
    if (!cooklang and dialect == null) return error.Usage;
    // Flags must belong to the command they are given with: `--to`
    // selects the renderer profile (render only), `--factor` /
    // `--servings` configure scaling (scale only), serialize/scale/menu
    // are Cooklang capabilities only, the Markdown extension flags are
    // Markdown-frontend options, and `--frontmatter` is a render
    // option shared by every frontend.
    const ext_flags = footnotes or definition_lists or heading_attributes or
        strikethrough or wikilinks or callouts or smartypants or heading_ids;
    switch (cmd) {
        .render => {
            if (factor_num != null or servings_target != null) return error.Usage;
            // The Markdown extensions cannot apply to Textile or
            // Cooklang; rejecting them keeps the strict scoping rule.
            if (ext_flags and dialect != .markdown) return error.Usage;
        },
        .serialize, .menu => {
            if (!cooklang or saw_to or factor_num != null or servings_target != null or
                ext_flags or frontmatter != null) return error.Usage;
        },
        .scale => {
            if (!cooklang or saw_to or ext_flags or frontmatter != null) return error.Usage;
            // Scaling needs exactly one mode: factor or servings.
            if ((factor_num == null) == (servings_target == null)) return error.Usage;
        },
    }
    return .{
        .command = cmd,
        .dialect = dialect,
        .cooklang = cooklang,
        .factor_num = factor_num,
        .factor_den = factor_den,
        .servings_target = servings_target,
        .profile = profile,
        .footnotes = footnotes,
        .definition_lists = definition_lists,
        .heading_attributes = heading_attributes,
        .strikethrough = strikethrough,
        .wikilinks = wikilinks,
        .callouts = callouts,
        .smartypants = smartypants,
        .heading_ids = heading_ids,
        .frontmatter = frontmatter,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // program name
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);
    while (it.next()) |arg| try args.append(gpa, arg);

    // `--help`/`-h` is a requested outcome: print usage and exit 0.
    // Anything else that `parseArgs` rejects is a real usage error and
    // exits 1 with the same text on stderr.
    const cfg = parseArgs(args.items) catch |err| switch (err) {
        error.Help => {
            printUsage();
            return 0;
        },
        // `--version` is a requested outcome like `--help`: print the
        // version and the embedded source commit, then exit 0.
        error.Version => return version(init),
        error.Usage => return usage(),
    };
    const profile = cfg.profile;

    // Read all of stdin into memory.
    var input = std.ArrayList(u8).empty;
    defer input.deinit(gpa);
    const stdin_file = std.Io.File.stdin();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.readStreaming(init.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try input.appendSlice(gpa, buf[0..n]);
    }

    // Render directly to stdout through a buffered writer.
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);

    if (cfg.cooklang) {
        var result = oliver.cooklang.parse(gpa, input.items, cooklangParseOptions(cfg)) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        switch (cfg.command) {
            .serialize => {
                oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
                    std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
            .scale => {
                const scaled = scaleWith(gpa, input.items, cfg) catch |err| {
                    std.debug.print("oliver: scale failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                defer gpa.free(scaled);
                out_writer.interface.writeAll(scaled) catch {};
            },
            .menu => {
                var m = oliver.cooklang_menu.menuView(gpa, &result.recipe) catch |err| {
                    std.debug.print("oliver: menu view failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                defer m.deinit();
                oliver.cooklang_menu.writeMenu(&out_writer.interface, &m) catch |err| {
                    std.debug.print("oliver: menu dump failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
            .render => {
                oliver.cooklang_html.render(gpa, &out_writer.interface, &result.recipe, .{ .profile = profile }) catch |err| {
                    std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
        }
    } else {
        const html_bytes = renderWith(gpa, cfg, input.items) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            if (err == error.RawHtmlNotXmlWellFormed) {
                std.debug.print(
                    "oliver: --to xhtml rejects raw HTML that cannot be guaranteed well-formed XML\n" ++
                        "(docs/XHTML.md section 5): remove or escape the raw HTML, or render with --to html.\n",
                    .{},
                );
            }
            return 1;
        };
        defer gpa.free(html_bytes);
        out_writer.interface.writeAll(html_bytes) catch {};
    }
    out_writer.flush() catch {};
    return 0;
}

// ---------------------------------------------------------------------------
// The render path, shared by `main` and the CLI tests so the tested path
// is the shipped path.
// ---------------------------------------------------------------------------

/// The Markdown/Textile parse options selected by the extension flags in
/// `cfg` (scoped to the render command by `parseArgs`).
fn markdownParseOptions(cfg: RunConfig) oliver.ParseOptions {
    var opts = oliver.ParseOptions{};
    opts.markdown = .{
        .footnotes = cfg.footnotes,
        .definition_lists = cfg.definition_lists,
        .heading_attributes = cfg.heading_attributes,
        .strikethrough = cfg.strikethrough,
        .wikilinks = cfg.wikilinks,
        .callouts = cfg.callouts,
        .smartypants = cfg.smartypants,
    };
    if (cfg.frontmatter) |fm| opts.frontmatter = fm;
    return opts;
}

/// The Cooklang parse options selected by `cfg` (front matter only; the
/// Markdown extensions do not apply to Cooklang).
fn cooklangParseOptions(cfg: RunConfig) oliver.cooklang.ParseOptions {
    var opts = oliver.cooklang.ParseOptions{};
    if (cfg.frontmatter) |fm| opts.frontmatter = fm;
    return opts;
}

/// The renderer options for the extension flags in `cfg`. The footnotes
/// extension has a render side: references and the `<section>` emit only
/// when this option is on (docs/MARKDOWN-EXTENSIONS.md).
fn renderOptionsFor(cfg: RunConfig) oliver.html.RenderOptions {
    return .{
        .profile = cfg.profile,
        .footnotes = cfg.footnotes,
        .heading_ids = cfg.heading_ids,
    };
}

/// Renders a Markdown/Textile document with the extension options from
/// `cfg`. Returns the owned HTML bytes; the caller frees with the same
/// allocator.
fn renderWith(a: std.mem.Allocator, cfg: RunConfig, input: []const u8) ![]u8 {
    var result = try oliver.parse(a, input, cfg.dialect.?, markdownParseOptions(cfg));
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try oliver.html.render(a, &aw.writer, &result.document, renderOptionsFor(cfg));
    var out = aw.toArrayList();
    return out.toOwnedSlice(a);
}

/// Scales a Cooklang recipe with the `--factor` / `--servings` mode from
/// `cfg` (scoped to the scale command by `parseArgs`) and serializes the
/// result. Returns the owned canonical `.cook` bytes; the caller frees
/// with the same allocator.
fn scaleWith(a: std.mem.Allocator, input: []const u8, cfg: RunConfig) ![]u8 {
    var result = try oliver.cooklang.parse(a, input, cooklangParseOptions(cfg));
    defer result.deinit();
    const by: oliver.cooklang_scale.ScaleBy = if (cfg.factor_num) |n|
        .{ .factor = .{ .num = n, .den = cfg.factor_den orelse 1 } }
    else
        .{ .servings = cfg.servings_target.? };
    var scaled = try oliver.cooklang_scale.scaleRecipe(a, &result.recipe, by);
    defer scaled.deinit();
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try oliver.cooklang_serialize.serialize(a, &aw.writer, &scaled, .{});
    var out = aw.toArrayList();
    return out.toOwnedSlice(a);
}

fn printUsage() void {
    std.debug.print(
        \\usage: oliver render --from <markdown|textile|cooklang> [--to <html|xhtml>]
        \\       oliver serialize --from cooklang
        \\       oliver scale --from cooklang (--factor <scalable> | --servings <n>)
        \\       oliver menu --from cooklang
        \\       oliver --version
        \\
        \\Reads a document from stdin and writes rendered HTML to stdout
        \\(XHTML fragment with --to xhtml). serialize/scale write canonical
        \\Cooklang text; menu writes the day/meal text dump. --version prints
        \\the version and the embedded source commit (CI builds).
        \\scale --factor accepts the same scalable quantity forms as amounts
        \\(2, 1/2, 1.5, 1 1/2; quote values containing spaces).
        \\
        \\Markdown extensions (render --from markdown, all off by default):
        \\  --wikilinks  --callouts  --smartypants  --footnotes
        \\  --definition-lists  --heading-attributes  --strikethrough
        \\  --heading-ids  (GFM-style auto ids on headings)
        \\Front matter (render with any frontend, off by default):
        \\  --frontmatter yaml|toml
        \\
    , .{});
}

fn usage() u8 {
    printUsage();
    return 1;
}

/// `--version` is a requested outcome: print the package version and, for
/// CI builds that embedded one, the exact source commit, then exit 0.
/// Written to stdout (not stderr) so a consumer can parse it: an
/// installer asserts the reported commit equals its pin.
fn version(init: std.process.Init) u8 {
    const text = if (build_options.commit.len == 0)
        std.fmt.allocPrint(init.gpa, "oliver {s}\n", .{build_options.version}) catch return 1
    else
        std.fmt.allocPrint(init.gpa, "oliver {s} (commit {s})\n", .{ build_options.version, build_options.commit }) catch return 1;
    defer init.gpa.free(text);
    std.Io.File.stdout().writeStreamingAll(init.io, text) catch return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// CLI argument parsing tests (pure: no allocator, no I/O).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cli: default profile is html and --to xhtml selects the xhtml profile" {
    const cfg = try parseArgs(&.{ "render", "--from", "markdown" });
    try testing.expectEqual(oliver.OutputProfile.html, cfg.profile);
    try testing.expectEqual(oliver.Dialect.markdown, cfg.dialect.?);

    const xhtml_cfg = try parseArgs(&.{ "render", "--from", "textile", "--to", "xhtml" });
    try testing.expectEqual(oliver.OutputProfile.xhtml, xhtml_cfg.profile);

    const explicit_html = try parseArgs(&.{ "render", "--from", "markdown", "--to", "html" });
    try testing.expectEqual(oliver.OutputProfile.html, explicit_html.profile);
}

test "cli: --to xhtml reaches the cooklang render path" {
    const cfg = try parseArgs(&.{ "render", "--from", "cooklang", "--to", "xhtml" });
    try testing.expect(cfg.cooklang);
    try testing.expectEqual(oliver.OutputProfile.xhtml, cfg.profile);
    try testing.expectEqual(Command.render, cfg.command);
}

test "cli: missing, duplicated, or conflicting subcommands are rejected" {
    // Regression (issue #57): a bare `--from cooklang` used to be
    // accepted and silently dispatch to render; now the subcommand is
    // required and may appear exactly once.
    try testing.expectError(error.Usage, parseArgs(&.{ "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "render" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "serialize" }));
    try testing.expectError(error.Usage, parseArgs(&.{}));
}

test "cli: flags are scoped to the command that owns them" {
    // `--factor`/`--servings` belong to `scale` only.
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "cooklang", "--factor", "2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--factor", "2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--servings", "4" }));
}

test "cli: --from must name a supported dialect and appear at most once" {
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "asciidoc" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "cooklang", "--from", "markdown" }));
}

test "cli: --help and -h are requested outcomes, not errors" {
    try testing.expectError(error.Help, parseArgs(&.{"--help"}));
    try testing.expectError(error.Help, parseArgs(&.{ "render", "--from", "markdown", "-h" }));
}

test "cli: --version is a requested outcome, not an error" {
    try testing.expectError(error.Version, parseArgs(&.{"--version"}));
    try testing.expectError(error.Version, parseArgs(&.{ "render", "--from", "markdown", "--version" }));
}

test "cli: invalid --to values and missing values fail clearly" {
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--to", "xml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--to" }));
}

test "cli: --to is rejected on the non-HTML cooklang commands" {
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--to", "xhtml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--to", "html" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--to", "xhtml" }));
}

test "cli: cooklang-only commands and scale modes keep their rules" {
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "markdown" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--servings", "4" }));
    const ok = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "3/2" });
    try testing.expectEqual(@as(u32, 3), ok.factor_num.?);
    try testing.expectEqual(@as(u32, 2), ok.factor_den.?);
}

test "cli: zero scale factors are rejected, not passed to the library" {
    // Regression (issue #55): a zero numerator used to reach
    // `scaleRecipe` and panic with a division by zero. Reject it at the
    // argument layer, symmetric with `--servings 0` and a zero `den`.
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "0" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "0/2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2/0" }));
}

test "cli: --factor parses the full scalable grammar through parseFactor" {
    // The library's parseFactor owns the grammar, so the CLI accepts the
    // same scalable forms as amounts (issue #85) and rejects the same
    // non-canonical shapes, including leading zeros.
    const decimal = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1.5" });
    try testing.expectEqual(@as(u32, 3), decimal.factor_num.?);
    try testing.expectEqual(@as(u32, 2), decimal.factor_den.?);
    const mixed = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1 1/2" });
    try testing.expectEqual(@as(u32, 3), mixed.factor_num.?);
    try testing.expectEqual(@as(u32, 2), mixed.factor_den.?);
    const spaced = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1 / 2" });
    try testing.expectEqual(@as(u32, 1), spaced.factor_num.?);
    try testing.expectEqual(@as(u32, 2), spaced.factor_den.?);

    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "01/2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1/2/3" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "some" }));
    // Above the u32 cap that matches ScaleBy.factor (issue #86).
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "4294967296" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1/4294967296" }));

    // Duplicate value flags contradict each other (the --from rule).
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--factor", "3" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--servings", "2", "--servings", "4" }));
}

test "cli: --factor grammar reaches the scale path end to end" {
    const allocator = std.testing.allocator;
    const decimal = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1.5" });
    const out = try scaleWith(allocator, "Add @x{2}.\n", decimal);
    defer allocator.free(out);
    try testing.expectEqualStrings("Add @x{3}.\n", out);

    const mixed = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "1 1/2" });
    const out2 = try scaleWith(allocator, "Add @flour{2%cup}.\n", mixed);
    defer allocator.free(out2);
    try testing.expectEqualStrings("Add @flour{3%cup}.\n", out2);
}

test "cli: markdown extension flags are scoped to render --from markdown" {
    const wl = try parseArgs(&.{ "render", "--from", "markdown", "--wikilinks" });
    try testing.expect(wl.wikilinks);
    const co = try parseArgs(&.{ "render", "--from", "markdown", "--callouts" });
    try testing.expect(co.callouts);
    const sp = try parseArgs(&.{ "render", "--from", "markdown", "--smartypants" });
    try testing.expect(sp.smartypants);
    const hi = try parseArgs(&.{ "render", "--from", "markdown", "--heading-ids" });
    try testing.expect(hi.heading_ids);
    const all = try parseArgs(&.{ "render", "--from", "markdown", "--footnotes", "--definition-lists", "--heading-attributes", "--strikethrough" });
    try testing.expect(all.footnotes and all.definition_lists and all.heading_attributes and all.strikethrough);

    // A flag that cannot apply is an error (the --to-on-serialize rule).
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "textile", "--wikilinks" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "cooklang", "--smartypants" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "textile", "--heading-ids" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--callouts" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--footnotes" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--wikilinks" }));
}

test "cli: --frontmatter is a render option shared by every frontend" {
    const md = try parseArgs(&.{ "render", "--from", "markdown", "--frontmatter", "yaml" });
    try testing.expectEqual(oliver.frontmatter.Option.yaml, md.frontmatter.?);
    const tx = try parseArgs(&.{ "render", "--from", "textile", "--frontmatter", "toml" });
    try testing.expectEqual(oliver.frontmatter.Option.toml, tx.frontmatter.?);
    const ck = try parseArgs(&.{ "render", "--from", "cooklang", "--frontmatter", "yaml" });
    try testing.expectEqual(oliver.frontmatter.Option.yaml, ck.frontmatter.?);

    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--frontmatter", "json" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--frontmatter" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--frontmatter", "yaml", "--frontmatter", "toml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--frontmatter", "yaml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--frontmatter", "yaml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--frontmatter", "yaml" }));
}

test "cli: the four new markdown extensions render end to end" {
    const allocator = std.testing.allocator;

    // Wikilinks resolve under the default policy (target percent-encoded
    // href, label orelse target as text).
    const wl = try parseArgs(&.{ "render", "--from", "markdown", "--wikilinks" });
    const wl_out = try renderWith(allocator, wl, "See [[Page Name]] now.\n");
    defer allocator.free(wl_out);
    try testing.expect(std.mem.indexOf(u8, wl_out, "<a href=\"Page%20Name\">Page Name</a>") != null);

    // Callouts become the semantic box with the inline-parsed title.
    const co = try parseArgs(&.{ "render", "--from", "markdown", "--callouts" });
    const co_out = try renderWith(allocator, co, "> [!note] Title\n> body\n");
    defer allocator.free(co_out);
    try testing.expect(std.mem.indexOf(u8, co_out, "<div class=\"callout callout-note\">") != null);
    try testing.expect(std.mem.indexOf(u8, co_out, "<div class=\"callout-title\">Title</div>") != null);

    // Smart typography applies the curly quotes and the em dash.
    const sp = try parseArgs(&.{ "render", "--from", "markdown", "--smartypants" });
    const sp_out = try renderWith(allocator, sp, "\"Hello\" -- world\n");
    defer allocator.free(sp_out);
    try testing.expect(std.mem.indexOf(u8, sp_out, "“Hello” — world") != null);

    // Front matter: the fence is consumed and the body renders; the same
    // input without the flag keeps `---` a thematic break (control).
    const fm = try parseArgs(&.{ "render", "--from", "markdown", "--frontmatter", "yaml" });
    const fm_out = try renderWith(allocator, fm, "---\ntitle: Hello\n---\n\n# Doc\n");
    defer allocator.free(fm_out);
    try testing.expect(std.mem.indexOf(u8, fm_out, "<h1>Doc</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, fm_out, "<hr") == null);
    const plain = try parseArgs(&.{ "render", "--from", "markdown" });
    const plain_out = try renderWith(allocator, plain, "---\ntitle: Hello\n---\n\n# Doc\n");
    defer allocator.free(plain_out);
    try testing.expect(std.mem.indexOf(u8, plain_out, "<hr") != null);
}

test "cli: the legacy markdown extensions render end to end" {
    const allocator = std.testing.allocator;

    const dl = try parseArgs(&.{ "render", "--from", "markdown", "--definition-lists" });
    const dl_out = try renderWith(allocator, dl, "Term\n: definition\n");
    defer allocator.free(dl_out);
    try testing.expect(std.mem.indexOf(u8, dl_out, "<dl>") != null);
    try testing.expect(std.mem.indexOf(u8, dl_out, "<dt>Term</dt>") != null);

    const ha = try parseArgs(&.{ "render", "--from", "markdown", "--heading-attributes" });
    const ha_out = try renderWith(allocator, ha, "# Head {#id .cls}\n");
    defer allocator.free(ha_out);
    try testing.expect(std.mem.indexOf(u8, ha_out, "<h1 id=\"id\" class=\"cls\">Head</h1>") != null);

    const st = try parseArgs(&.{ "render", "--from", "markdown", "--strikethrough" });
    const st_out = try renderWith(allocator, st, "~~gone~~\n");
    defer allocator.free(st_out);
    try testing.expect(std.mem.indexOf(u8, st_out, "<p><del>gone</del></p>") != null);

    // Footnotes have a render side too: the references and the section
    // emit only when the render option is on (renderWith threads it).
    const fn_ = try parseArgs(&.{ "render", "--from", "markdown", "--footnotes" });
    const fn_out = try renderWith(allocator, fn_, "Ref[^1].\n\n[^1]: note\n");
    defer allocator.free(fn_out);
    try testing.expect(std.mem.indexOf(u8, fn_out, "class=\"footnote-ref\"") != null);
    try testing.expect(std.mem.indexOf(u8, fn_out, "<section class=\"footnotes\"") != null);
}

test "cli: --heading-ids renders GFM-style heading ids end to end" {
    const allocator = std.testing.allocator;
    const hi = try parseArgs(&.{ "render", "--from", "markdown", "--heading-ids" });
    const hi_out = try renderWith(allocator, hi, "# Head\n\n## A \"quoted\" -- heading!\n");
    defer allocator.free(hi_out);
    try testing.expect(std.mem.indexOf(u8, hi_out, "<h1 id=\"head\">Head</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, hi_out, "<h2 id=\"a-quoted----heading\">") != null);
}

test "cli: --frontmatter reaches the cooklang render path" {
    const allocator = std.testing.allocator;
    const input = "+++\ntitle = \"x\"\n+++\nAdd @salt.\n";

    // With --frontmatter toml the +++ fence is consumed; the default
    // (yaml sniffing) leaves it as body text.
    const toml = try parseArgs(&.{ "render", "--from", "cooklang", "--frontmatter", "toml" });
    var result = try oliver.cooklang.parse(allocator, input, cooklangParseOptions(toml));
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try oliver.cooklang_html.render(allocator, &aw.writer, &result.recipe, .{ .profile = toml.profile });
    var out = aw.toArrayList();
    defer out.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "+++") == null);

    const plain = try parseArgs(&.{ "render", "--from", "cooklang" });
    var result2 = try oliver.cooklang.parse(allocator, input, cooklangParseOptions(plain));
    defer result2.deinit();
    var aw2 = std.Io.Writer.Allocating.init(allocator);
    defer aw2.deinit();
    try oliver.cooklang_html.render(allocator, &aw2.writer, &result2.recipe, .{ .profile = plain.profile });
    var out2 = aw2.toArrayList();
    defer out2.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, out2.items, "+++") != null);
}
