//! Phase 6 S4 — `oliver plan` (13-col TSV batch).
//!
//! - Discovery `*.md|*.textile|*.cook` via `std.Io.Dir.walk`
//! - `strip_source_ext` → `dst = output/reldir/base.html`
//! - Collision abort (`dst` → `rel` map)
//! - `ASSETS_ROOT` = `rk_up_dirs(depth+1)` + `assets/`
//! - `soul = meta_dir/strip_source_ext(rel).soul.md` or `NONE`
//! - Passthrough cols 3/6/7/8/9/10/11/12/13 unchanged.
//!
//! Filesystem is CLI-only (not library). Deterministic, sorted srcs.

const std = @import("std");

fn isSourceFile(basename: []const u8) bool {
    return std.mem.endsWith(u8, basename, ".md") or
        std.mem.endsWith(u8, basename, ".textile") or
        std.mem.endsWith(u8, basename, ".cook");
}

fn stripSourceExt(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".md")) return path[0 .. path.len - 3];
    if (std.mem.endsWith(u8, path, ".textile")) return path[0 .. path.len - 8];
    if (std.mem.endsWith(u8, path, ".cook")) return path[0 .. path.len - 5];
    return path;
}

fn countSlashes(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '/') n += 1;
    }
    return n;
}

fn upDirs(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const out_len = n * 3; // "../" * n
    var buf = try allocator.alloc(u8, out_len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const off = i * 3;
        buf[off] = '.';
        buf[off + 1] = '.';
        buf[off + 2] = '/';
    }
    return buf;
}

/// Writes the 13-col TSV to `writer`. On basename collision prints to
/// stderr via `std.debug.print` and returns `error.Collision`.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    content_dir: []const u8,
    output_dir: []const u8,
    template_dir: []const u8,
    meta_dir: []const u8,
    default_template: []const u8,
    oliver_bin: []const u8,
    root_dir: []const u8,
    dry_run: []const u8,
    verbose: []const u8,
    writer: anytype,
) !void {
    // Open content_dir for walking.
    const content_dir_handle = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, content_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("oliver plan: cannot open --content-dir {s}: {s}\n", .{ content_dir, @errorName(err) });
        return err;
    };
    defer content_dir_handle.close(io);

    var walker = try content_dir_handle.walk(gpa);
    defer walker.deinit();

    var srcs = std.ArrayList([]u8).empty;
    defer {
        for (srcs.items) |s| gpa.free(s);
        srcs.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isSourceFile(entry.basename)) continue;
        const rel = entry.path;
        const src = try std.fs.path.join(gpa, &.{ content_dir, rel });
        try srcs.append(gpa, src);
    }

    // Deterministic: sort srcs alphabetically (Bash glob is sorted).
    std.mem.sort([]u8, srcs.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var seen = std.StringHashMap([]const u8).init(gpa);
    defer {
        var it = seen.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        seen.deinit();
    }

    for (srcs.items) |src| {
        var rel: []const u8 = undefined;
        if (std.mem.startsWith(u8, src, content_dir)) {
            var start: usize = content_dir.len;
            if (start < src.len and src[start] == '/') start += 1;
            rel = src[start..];
            if (rel.len == 0) rel = std.fs.path.basename(src);
        } else {
            rel = std.fs.path.basename(src);
        }

        const base_with_ext = std.fs.path.basename(rel);
        const base = stripSourceExt(base_with_ext);
        const reldir_opt = std.fs.path.dirname(rel);
        const reldir = reldir_opt orelse ".";

        const dst = if (std.mem.eql(u8, reldir, ".")) blk: {
            const fname = try std.mem.concat(gpa, u8, &.{ base, ".html" });
            defer gpa.free(fname);
            break :blk try std.fs.path.join(gpa, &.{ output_dir, fname });
        } else blk: {
            const filename = try std.mem.concat(gpa, u8, &.{ base, ".html" });
            defer gpa.free(filename);
            break :blk try std.fs.path.join(gpa, &.{ output_dir, reldir, filename });
        };
        defer gpa.free(dst);

        if (seen.get(dst)) |prev_rel| {
            std.debug.print("oliver plan: basename collision: '{s}' and '{s}' both map to '{s}'\n", .{ prev_rel, rel, dst });
            return error.Collision;
        }
        const rel_copy = try gpa.dupe(u8, rel);
        errdefer gpa.free(rel_copy);
        const dst_copy = try gpa.dupe(u8, dst);
        errdefer gpa.free(dst_copy);
        try seen.put(dst_copy, rel_copy);

        const assets_root = if (std.mem.eql(u8, reldir, ".")) blk: {
            break :blk try gpa.dupe(u8, "./assets/");
        } else blk: {
            const depth = countSlashes(reldir);
            const ups = try upDirs(gpa, depth + 1);
            defer gpa.free(ups);
            break :blk try std.mem.concat(gpa, u8, &.{ ups, "assets/" });
        };
        defer gpa.free(assets_root);

        const stripped_rel = stripSourceExt(rel);
        const soul_rel = try std.mem.concat(gpa, u8, &.{ stripped_rel, ".soul.md" });
        defer gpa.free(soul_rel);
        const soul_path = try std.fs.path.join(gpa, &.{ meta_dir, soul_rel });
        defer gpa.free(soul_path);

        var soul_final: []const u8 = "NONE";
        var soul_buf: ?[]u8 = null;
        defer if (soul_buf) |b| gpa.free(b);
        const cwd = std.Io.Dir.cwd();
        if (cwd.statFile(io, soul_path, .{}) catch null) |_| {
            soul_buf = try gpa.dupe(u8, soul_path);
            soul_final = soul_buf.?;
        } else {
            if (cwd.openFile(io, soul_path, .{}) catch null) |f| {
                f.close(io);
                soul_buf = try gpa.dupe(u8, soul_path);
                soul_final = soul_buf.?;
            } else {
                soul_final = "NONE";
            }
        }

        const template = try std.fs.path.join(gpa, &.{ template_dir, default_template });
        defer gpa.free(template);

        try writer.writeAll(src);
        try writer.writeByte('\t');
        try writer.writeAll(dst);
        try writer.writeByte('\t');
        try writer.writeAll(template);
        try writer.writeByte('\t');
        try writer.writeAll(assets_root);
        try writer.writeByte('\t');
        try writer.writeAll(soul_final);
        try writer.writeByte('\t');
        try writer.writeAll(oliver_bin);
        try writer.writeByte('\t');
        try writer.writeAll(root_dir);
        try writer.writeByte('\t');
        try writer.writeAll(content_dir);
        try writer.writeByte('\t');
        try writer.writeAll(output_dir);
        try writer.writeByte('\t');
        try writer.writeAll(template_dir);
        try writer.writeByte('\t');
        try writer.writeAll(meta_dir);
        try writer.writeByte('\t');
        try writer.writeAll(dry_run);
        try writer.writeByte('\t');
        try writer.writeAll(verbose);
        try writer.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "plan: stripSourceExt and countSlashes and upDirs" {
    try testing.expectEqualStrings("foo", stripSourceExt("foo.md"));
    try testing.expectEqualStrings("foo", stripSourceExt("foo.textile"));
    try testing.expectEqualStrings("foo", stripSourceExt("foo.cook"));
    try testing.expectEqualStrings("foo.txt", stripSourceExt("foo.txt"));
    try testing.expectEqual(@as(usize, 0), countSlashes("."));
    try testing.expectEqual(@as(usize, 0), countSlashes("foo"));
    try testing.expectEqual(@as(usize, 1), countSlashes("docs/foo"));
    try testing.expectEqual(@as(usize, 2), countSlashes("docs/x/y"));
    {
        const s = try upDirs(testing.allocator, 1);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("../", s);
    }
    {
        const s = try upDirs(testing.allocator, 3);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("../../../", s);
    }
    {
        const s = try upDirs(testing.allocator, 0);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("", s);
    }
}

test "plan: walk, dst, assets_root, soul, collision" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(base);
    const content_dir = try std.fs.path.join(testing.allocator, &.{ base, "content" });
    defer testing.allocator.free(content_dir);
    const output_dir = try std.fs.path.join(testing.allocator, &.{ base, "out" });
    defer testing.allocator.free(output_dir);
    const template_dir = try std.fs.path.join(testing.allocator, &.{ base, "templates" });
    defer testing.allocator.free(template_dir);
    const meta_dir = try std.fs.path.join(testing.allocator, &.{ base, "meta" });
    defer testing.allocator.free(meta_dir);

    var io = std.Io.Threaded.init(testing.allocator, .{});
    defer io.deinit();
    const threaded = io.io();

    try std.Io.Dir.cwd().createDirPath(threaded, content_dir);
    try std.Io.Dir.cwd().createDirPath(threaded, template_dir);
    try std.Io.Dir.cwd().createDirPath(threaded, meta_dir);
    {
        const tpath = try std.fs.path.join(testing.allocator, &.{ template_dir, "base.html" });
        defer testing.allocator.free(tpath);
        var f = try std.Io.Dir.cwd().createFile(threaded, tpath, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "<html></html>");
    }
    {
        const docs_path = try std.fs.path.join(testing.allocator, &.{ content_dir, "docs" });
        defer testing.allocator.free(docs_path);
        try std.Io.Dir.cwd().createDirPath(threaded, docs_path);
    }
    {
        const p = try std.fs.path.join(testing.allocator, &.{ content_dir, "foo.md" });
        defer testing.allocator.free(p);
        var f = try std.Io.Dir.cwd().createFile(threaded, p, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "hi");
    }
    {
        const p = try std.fs.path.join(testing.allocator, &.{ content_dir, "docs", "bar.textile" });
        defer testing.allocator.free(p);
        var f = try std.Io.Dir.cwd().createFile(threaded, p, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "hi");
    }
    {
        const deep = try std.fs.path.join(testing.allocator, &.{ content_dir, "docs", "x", "y" });
        defer testing.allocator.free(deep);
        try std.Io.Dir.cwd().createDirPath(threaded, deep);
        const p = try std.fs.path.join(testing.allocator, &.{ deep, "baz.cook" });
        defer testing.allocator.free(p);
        var f = try std.Io.Dir.cwd().createFile(threaded, p, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "hi");
    }
    {
        const s = try std.fs.path.join(testing.allocator, &.{ meta_dir, "foo.soul.md" });
        defer testing.allocator.free(s);
        var f = try std.Io.Dir.cwd().createFile(threaded, s, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "---\ntitle: x\n---\n");
    }

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try run(testing.allocator, threaded, content_dir, output_dir, template_dir, meta_dir, "base.html", "/usr/bin/oliver", base, "false", "false", &aw.writer);

    const tsv = aw.written();
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var col_count: usize = 0;
        while (cols.next()) |_| col_count += 1;
        try testing.expectEqual(@as(usize, 13), col_count);
        var c = std.mem.splitScalar(u8, line, '\t');
        const src = c.next().?;
        const dst = c.next().?;
        const tmpl = c.next().?;
        const assets = c.next().?;
        const soul = c.next().?;
        _ = src;
        _ = tmpl;
        if (std.mem.indexOf(u8, dst, "foo.html") != null) {
            try testing.expectEqualStrings("./assets/", assets);
            try testing.expect(std.mem.indexOf(u8, soul, "foo.soul.md") != null);
        } else if (std.mem.indexOf(u8, dst, "bar.html") != null) {
            try testing.expectEqualStrings("../assets/", assets);
            try testing.expectEqualStrings("NONE", soul);
        } else if (std.mem.indexOf(u8, dst, "baz.html") != null) {
            try testing.expectEqualStrings("../../../assets/", assets);
            try testing.expectEqualStrings("NONE", soul);
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "plan: collision abort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(base);
    const content_dir = try std.fs.path.join(testing.allocator, &.{ base, "content" });
    defer testing.allocator.free(content_dir);
    const output_dir = try std.fs.path.join(testing.allocator, &.{ base, "out" });
    defer testing.allocator.free(output_dir);
    const template_dir = try std.fs.path.join(testing.allocator, &.{ base, "templates" });
    defer testing.allocator.free(template_dir);
    const meta_dir = try std.fs.path.join(testing.allocator, &.{ base, "meta" });
    defer testing.allocator.free(meta_dir);
    var io = std.Io.Threaded.init(testing.allocator, .{});
    defer io.deinit();
    const threaded = io.io();
    try std.Io.Dir.cwd().createDirPath(threaded, content_dir);
    try std.Io.Dir.cwd().createDirPath(threaded, template_dir);
    try std.Io.Dir.cwd().createDirPath(threaded, meta_dir);
    {
        const p1 = try std.fs.path.join(testing.allocator, &.{ content_dir, "foo.md" });
        defer testing.allocator.free(p1);
        var f = try std.Io.Dir.cwd().createFile(threaded, p1, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "a");
    }
    {
        const p2 = try std.fs.path.join(testing.allocator, &.{ content_dir, "foo.textile" });
        defer testing.allocator.free(p2);
        var f = try std.Io.Dir.cwd().createFile(threaded, p2, .{});
        defer f.close(threaded);
        try f.writeStreamingAll(threaded, "b");
    }
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(error.Collision, run(testing.allocator, threaded, content_dir, output_dir, template_dir, meta_dir, "base.html", "/bin/oliver", base, "false", "false", &aw.writer));
}
