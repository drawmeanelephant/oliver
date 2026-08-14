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

/// The full command-line configuration, decided by `parseArgs`. Rendering
/// always happens; `serialize`/`scale`/`menu` select the non-HTML Cooklang
/// outputs instead. `profile` selects the renderer serialization (`html` by
/// default, `xhtml` with `--to xhtml`).
pub const RunConfig = struct {
    dialect: ?oliver.Dialect = null,
    cooklang: bool = false,
    serialize: bool = false,
    scale: bool = false,
    menu: bool = false,
    factor_num: ?u32 = null,
    factor_den: ?u32 = null,
    servings_target: ?u32 = null,
    profile: oliver.OutputProfile = .html,
};

/// Parses the argument vector (excluding the program name) into a
/// `RunConfig`. Returns `error.Usage` for any unknown flag, invalid value,
/// or nonsensical combination (e.g. `--to` with a non-rendering Cooklang
/// command). Pure: no allocator, no I/O, so it is unit-tested directly.
pub fn parseArgs(args: []const []const u8) error{Usage}!RunConfig {
    var cfg = RunConfig{};
    var saw_to = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--from")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            if (std.mem.eql(u8, value, "markdown")) {
                cfg.dialect = .markdown;
            } else if (std.mem.eql(u8, value, "textile")) {
                cfg.dialect = .textile;
            } else if (std.mem.eql(u8, value, "cooklang")) {
                cfg.cooklang = true;
            } else return error.Usage;
        } else if (std.mem.eql(u8, arg, "--to")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            if (std.mem.eql(u8, value, "html")) {
                cfg.profile = .html;
            } else if (std.mem.eql(u8, value, "xhtml")) {
                cfg.profile = .xhtml;
            } else return error.Usage;
            saw_to = true;
        } else if (std.mem.eql(u8, arg, "render")) {
            // Subcommand; the dialect flag is what matters.
        } else if (std.mem.eql(u8, arg, "serialize")) {
            cfg.serialize = true;
        } else if (std.mem.eql(u8, arg, "scale")) {
            cfg.scale = true;
        } else if (std.mem.eql(u8, arg, "menu")) {
            cfg.menu = true;
        } else if (std.mem.eql(u8, arg, "--factor")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            var parts = std.mem.splitScalar(u8, value, '/');
            const num = parts.next() orelse return error.Usage;
            cfg.factor_num = std.fmt.parseUnsigned(u32, num, 10) catch return error.Usage;
            if (parts.next()) |den| {
                cfg.factor_den = std.fmt.parseUnsigned(u32, den, 10) catch return error.Usage;
                if (cfg.factor_den.? == 0) return error.Usage;
            }
            if (parts.next() != null) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--servings")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            cfg.servings_target = std.fmt.parseUnsigned(u32, value, 10) catch return error.Usage;
            if (cfg.servings_target.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Usage;
        } else return error.Usage;
    }
    if (!cfg.cooklang and cfg.dialect == null) return error.Usage;
    // Serialization, scaling, and the menu view are Cooklang
    // capabilities only (Markdown/Textile have no canonical form; the
    // shared renderer is the output for those). Scaling needs exactly
    // one mode. `--to` selects the renderer profile, so it is invalid
    // on the non-HTML Cooklang commands.
    if ((cfg.serialize or cfg.scale or cfg.menu) and !cfg.cooklang) return error.Usage;
    if (cfg.scale and (cfg.factor_num == null) == (cfg.servings_target == null)) return error.Usage;
    if (saw_to and (cfg.serialize or cfg.scale or cfg.menu)) return error.Usage;
    return cfg;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // program name
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);
    while (it.next()) |arg| try args.append(gpa, arg);

    const cfg = parseArgs(args.items) catch return usage();
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
        var result = oliver.cooklang.parse(gpa, input.items, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        if (cfg.serialize) {
            oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
                std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else if (cfg.scale) {
            const by: oliver.cooklang_scale.ScaleBy = if (cfg.factor_num) |n|
                .{ .factor = .{ .num = n, .den = cfg.factor_den orelse 1 } }
            else
                .{ .servings = cfg.servings_target.? };
            var scaled = oliver.cooklang_scale.scaleRecipe(gpa, &result.recipe, by) catch |err| {
                std.debug.print("oliver: scale failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer scaled.deinit();
            oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &scaled, .{}) catch |err| {
                std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else if (cfg.menu) {
            var m = oliver.cooklang_menu.menuView(gpa, &result.recipe) catch |err| {
                std.debug.print("oliver: menu view failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer m.deinit();
            oliver.cooklang_menu.writeMenu(&out_writer.interface, &m) catch |err| {
                std.debug.print("oliver: menu dump failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else {
            oliver.cooklang_html.render(gpa, &out_writer.interface, &result.recipe, .{ .profile = profile }) catch |err| {
                std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
    } else {
        const d = cfg.dialect.?;
        var result = oliver.parse(gpa, input.items, d, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        oliver.html.render(gpa, &out_writer.interface, &result.document, .{ .profile = profile }) catch |err| {
            std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
            if (err == error.RawHtmlNotXmlWellFormed) {
                std.debug.print(
                    "oliver: --to xhtml rejects raw HTML that cannot be guaranteed well-formed XML\n" ++
                        "(docs/XHTML.md section 5): remove or escape the raw HTML, or render with --to html.\n",
                    .{},
                );
            }
            return 1;
        };
    }
    out_writer.flush() catch {};
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: oliver render --from <markdown|textile|cooklang> [--to <html|xhtml>]
        \\       oliver serialize --from cooklang
        \\       oliver scale --from cooklang (--factor <num[/den]> | --servings <n>)
        \\       oliver menu --from cooklang
        \\
        \\Reads a document from stdin and writes rendered HTML to stdout
        \\(XHTML fragment with --to xhtml). serialize/scale write canonical
        \\Cooklang text; menu writes the day/meal text dump.
        \\
    , .{});
    return 1;
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
    try testing.expect(!cfg.serialize and !cfg.scale and !cfg.menu);
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
