//! In-memory input budget shared by hosted and guest CLI adapters.

const std = @import("std");

pub const default_max_input_bytes: usize = 64 * 1024 * 1024;

/// Checks a pending chunk without overflowing or using hosted services.
/// The limit is inclusive and counts raw input bytes, not parser memory.
pub fn checkSize(current: usize, additional: usize, max_input_bytes: usize) error{InputTooLarge}!void {
    if (current > max_input_bytes or additional > max_input_bytes - current)
        return error.InputTooLarge;
}

/// Rejects an over-budget chunk before allocating or changing the buffer.
pub fn append(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    bytes: []const u8,
    max_input_bytes: usize,
) (std.mem.Allocator.Error || error{InputTooLarge})!void {
    try checkSize(buffer.items.len, bytes.len, max_input_bytes);
    try buffer.appendSlice(allocator, bytes);
}

test "input: under-limit and exact-limit chunks pass, over-limit leaves the buffer unchanged" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    try append(std.testing.allocator, &buffer, "abc", 4);
    try std.testing.expectEqualStrings("abc", buffer.items);
    try append(std.testing.allocator, &buffer, "d", 4);
    try std.testing.expectEqualStrings("abcd", buffer.items);
    try std.testing.expectError(error.InputTooLarge, append(std.testing.allocator, &buffer, "e", 4));
    try std.testing.expectEqualStrings("abcd", buffer.items);
}

test "input: oversized first chunk is rejected before allocation" {
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator.allocator());

    try std.testing.expectError(error.InputTooLarge, append(allocator.allocator(), &buffer, "abc", 2));
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.capacity);
}

test "input: zero budget permits only empty input" {
    try checkSize(0, 0, 0);
    try std.testing.expectError(error.InputTooLarge, checkSize(0, 1, 0));
}

test "input: size checks cannot overflow" {
    const max = std.math.maxInt(usize);
    try checkSize(max - 1, 1, max);
    try std.testing.expectError(error.InputTooLarge, checkSize(max, 1, max));
    try std.testing.expectError(error.InputTooLarge, checkSize(2, max, max));
    try std.testing.expectError(error.InputTooLarge, checkSize(2, 0, 1));
}

test "input: default budget is exactly 64 MiB and inclusive" {
    try std.testing.expectEqual(@as(usize, 67108864), default_max_input_bytes);
    try checkSize(default_max_input_bytes - 1, 1, default_max_input_bytes);
    try std.testing.expectError(error.InputTooLarge, checkSize(default_max_input_bytes, 1, default_max_input_bytes));
}
