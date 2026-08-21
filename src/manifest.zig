//! Phase 6 S5 — `oliver manifest` (deduped manifest log).
//!
//! - `oliver manifest --manifest <file> --add <rel>` → dedup `grep -Fxq` then `>>`
//!   (create parent dirs / touch if missing).
//! - `oliver manifest --manifest <file> --verify` → no-op 0 (future hook).
//! - `oliver manifest --help` → usage.
//!
//! Filesystem is CLI-only (not library).

const std = @import("std");

/// Runs the manifest command. `manifest_path` is required; exactly one of
/// `add` (value) or `verify` (true) must be set. Writes nothing on success
/// (Bash fallback echoes only on append). Returns error on usage violations.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
    add: ?[]const u8,
    verify: bool,
) !void {
    if (verify and add != null) return error.Usage;
    if (!verify and add == null) return error.Usage;

    if (verify) {
        // No-op today — must exist but always 0.
        return;
    }

    const rel = add.?;

    // Ensure parent dirs exist.
    if (std.fs.path.dirname(manifest_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.NotDir => {}, // "/tmp" on macOS is a symlink → treat as ok
            else => return err,
        };
    }

    const cwd = std.Io.Dir.cwd();

    // Try to open existing file read_write, else create.
    const file_exists = blk: {
        if (cwd.openFile(io, manifest_path, .{ .mode = .read_write }) catch null) |file| {
            defer file.close(io);

            // Read existing content for dedup.
            var buf: [8192]u8 = undefined;
            var content = std.ArrayList(u8).empty;
            defer content.deinit(gpa);
            while (true) {
                const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (n == 0) break;
                try content.appendSlice(gpa, buf[0..n]);
            }

            var it = std.mem.splitScalar(u8, content.items, '\n');
            while (it.next()) |line| {
                const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                if (trimmed.len == 0 and content.items.len == 0) continue;
                if (std.mem.eql(u8, trimmed, rel)) {
                    return;
                }
                // Handle last line without trailing newline: already checked.
            }
            // Not found — append at end.
            const len = try file.length(io);
            try file.writePositionalAll(io, rel, len);
            // Ensure newline; if file was empty len==0, just add rel + "\n"
            // If we wrote rel at len, now write "\n"
            try file.writePositionalAll(io, "\n", len + rel.len);
            break :blk true;
        } else {
            break :blk false;
        }
    };

    if (!file_exists) {
        // Create new file with rel + "\n"
        var file = try cwd.createFile(io, manifest_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, rel);
        try file.writeStreamingAll(io, "\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "manifest: --add creates file and dedups" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(base);
    const manifest = try std.fs.path.join(testing.allocator, &.{ base, "sub", "manifest.txt" });
    defer testing.allocator.free(manifest);

    var io = std.Io.Threaded.init(testing.allocator, .{});
    defer io.deinit();
    const threaded = io.io();

    try run(testing.allocator, threaded, manifest, "output/probe.html", false);
    // Verify file contains one line
    {
        var file = try std.Io.Dir.cwd().openFile(threaded, manifest, .{});
        defer file.close(threaded);
        var buf: [8192]u8 = undefined;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(testing.allocator);
        while (true) {
            const n = file.readStreaming(threaded, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try content.appendSlice(testing.allocator, buf[0..n]);
        }
        try testing.expectEqualStrings("output/probe.html\n", content.items);
    }
    // Second add same rel → no duplicate
    try run(testing.allocator, threaded, manifest, "output/probe.html", false);
    {
        var file = try std.Io.Dir.cwd().openFile(threaded, manifest, .{});
        defer file.close(threaded);
        var buf: [8192]u8 = undefined;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(testing.allocator);
        while (true) {
            const n = file.readStreaming(threaded, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try content.appendSlice(testing.allocator, buf[0..n]);
        }
        try testing.expectEqualStrings("output/probe.html\n", content.items);
    }
    // Add second rel
    try run(testing.allocator, threaded, manifest, "output/other.html", false);
    {
        var file = try std.Io.Dir.cwd().openFile(threaded, manifest, .{});
        defer file.close(threaded);
        var buf: [8192]u8 = undefined;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(testing.allocator);
        while (true) {
            const n = file.readStreaming(threaded, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try content.appendSlice(testing.allocator, buf[0..n]);
        }
        try testing.expectEqualStrings("output/probe.html\noutput/other.html\n", content.items);
    }
}

test "manifest: --verify is no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(base);
    const manifest = try std.fs.path.join(testing.allocator, &.{ base, "manifest.txt" });
    defer testing.allocator.free(manifest);

    var io = std.Io.Threaded.init(testing.allocator, .{});
    defer io.deinit();
    const threaded = io.io();

    // verify on non-existent file should still succeed (no-op)
    try run(testing.allocator, threaded, manifest, null, true);
    // add then verify
    try run(testing.allocator, threaded, manifest, "x", false);
    try run(testing.allocator, threaded, manifest, null, true);
}

test "manifest: usage errors" {
    var io = std.Io.Threaded.init(testing.allocator, .{});
    defer io.deinit();
    const threaded = io.io();
    try testing.expectError(error.Usage, run(testing.allocator, threaded, "m.txt", null, false));
    try testing.expectError(error.Usage, run(testing.allocator, threaded, "m.txt", "a", true));
}
