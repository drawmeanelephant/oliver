//! Provisional CLI: a thin adapter over the library for shell integration.
//!
//!     oliver render --from markdown < document.md > document.html
//!     oliver render --from textile  < document.textile
//!     oliver render --from cooklang < recipe.cook
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
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else return usage();
    }
    if (!cooklang and dialect == null) return usage();

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
        oliver.cooklang_html.render(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
            std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
            return 1;
        };
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
        \\
        \\Reads a document from stdin and writes rendered HTML to stdout.
        \\
    , .{});
    return 1;
}
