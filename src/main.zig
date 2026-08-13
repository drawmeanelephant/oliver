//! Provisional CLI: a thin adapter over the library for shell integration.
//!
//!     oliver render    --from markdown < document.md > document.html
//!     oliver render    --from textile  < document.textile
//!     oliver render    --from cooklang < recipe.cook
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

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // program name

    var dialect: ?oliver.Dialect = null;
    var cooklang = false;
    var serialize = false;
    var scale = false;
    var menu = false;
    var factor_num: ?u32 = null;
    var factor_den: ?u32 = null;
    var servings_target: ?u32 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--from")) {
            const value = it.next() orelse return usage();
            if (std.mem.eql(u8, value, "markdown")) {
                dialect = .markdown;
            } else if (std.mem.eql(u8, value, "textile")) {
                dialect = .textile;
            } else if (std.mem.eql(u8, value, "cooklang")) {
                cooklang = true;
            } else return usage();
        } else if (std.mem.eql(u8, arg, "render")) {
            // Subcommand; the dialect flag is what matters.
        } else if (std.mem.eql(u8, arg, "serialize")) {
            serialize = true;
        } else if (std.mem.eql(u8, arg, "scale")) {
            scale = true;
        } else if (std.mem.eql(u8, arg, "menu")) {
            menu = true;
        } else if (std.mem.eql(u8, arg, "--factor")) {
            const value = it.next() orelse return usage();
            var parts = std.mem.splitScalar(u8, value, '/');
            const num = parts.next() orelse return usage();
            factor_num = std.fmt.parseUnsigned(u32, num, 10) catch return usage();
            if (parts.next()) |den| {
                factor_den = std.fmt.parseUnsigned(u32, den, 10) catch return usage();
                if (factor_den.? == 0) return usage();
            }
            if (parts.next() != null) return usage();
        } else if (std.mem.eql(u8, arg, "--servings")) {
            const value = it.next() orelse return usage();
            servings_target = std.fmt.parseUnsigned(u32, value, 10) catch return usage();
            if (servings_target.? == 0) return usage();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else return usage();
    }
    if (!cooklang and dialect == null) return usage();
    // Serialization, scaling, and the menu view are Cooklang
    // capabilities only (Markdown/Textile have no canonical form; the
    // shared renderer is the output for those). Scaling needs exactly
    // one mode.
    if ((serialize or scale or menu) and !cooklang) return usage();
    if (scale and (factor_num == null) == (servings_target == null)) return usage();

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

    if (cooklang) {
        var result = oliver.cooklang.parse(gpa, input.items, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        if (serialize) {
            oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
                std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else if (scale) {
            const by: oliver.cooklang_scale.ScaleBy = if (factor_num) |n|
                .{ .factor = .{ .num = n, .den = factor_den orelse 1 } }
            else
                .{ .servings = servings_target.? };
            var scaled = oliver.cooklang_scale.scaleRecipe(gpa, &result.recipe, by) catch |err| {
                std.debug.print("oliver: scale failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer scaled.deinit();
            oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &scaled, .{}) catch |err| {
                std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else if (menu) {
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
            oliver.cooklang_html.render(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
                std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
    } else {
        const d = dialect.?;
        var result = oliver.parse(gpa, input.items, d, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        oliver.html.render(gpa, &out_writer.interface, &result.document, .{}) catch |err| {
            std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    out_writer.flush() catch {};
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: oliver render --from <markdown|textile|cooklang>
        \\       oliver serialize --from cooklang
        \\       oliver scale --from cooklang (--factor <num[/den]> | --servings <n>)
        \\       oliver menu --from cooklang
        \\
        \\Reads a document from stdin and writes rendered HTML (or, for
        \\serialize/scale, canonical Cooklang text; for menu, the
        \\day/meal text dump) to stdout.
        \\
    , .{});
    return 1;
}
