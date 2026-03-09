const std = @import("std");
const Hash = @import("hash.zig").Hash;

pub const TreeEntry = struct {
    path: []const u8,
    mode: u16,
    size: u64,
    mtime_ns: i128, // nanosecond mtime for change detection
    chunk_hashes: []const Hash,
};

/// Binary format per entry:
///   [2] path_len  [N] path  [2] mode  [8] size  [16] mtime_ns  [4] chunk_count  [32*N] hashes
pub fn serialize(allocator: std.mem.Allocator, entries: []const TreeEntry) ![]u8 {
    // Pre-calculate total size to avoid repeated reallocs
    var total: usize = 4; // entry count
    for (entries) |entry| {
        total += 2 + entry.path.len + 2 + 8 + 16 + 4 + (32 * entry.chunk_hashes.len);
    }

    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;

    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(entries.len), .little);
    pos += 4;

    for (entries) |entry| {
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(entry.path.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..entry.path.len], entry.path);
        pos += entry.path.len;

        std.mem.writeInt(u16, buf[pos..][0..2], entry.mode, .little);
        pos += 2;
        std.mem.writeInt(u64, buf[pos..][0..8], entry.size, .little);
        pos += 8;
        std.mem.writeInt(i128, buf[pos..][0..16], entry.mtime_ns, .little);
        pos += 16;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(entry.chunk_hashes.len), .little);
        pos += 4;
        for (entry.chunk_hashes) |h| {
            @memcpy(buf[pos..][0..32], &h);
            pos += 32;
        }
    }

    return buf;
}

pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) ![]TreeEntry {
    var pos: usize = 0;

    const count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    const entries = try allocator.alloc(TreeEntry, count);
    errdefer allocator.free(entries);

    for (entries) |*entry| {
        const path_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        entry.path = try allocator.dupe(u8, data[pos..][0..path_len]);
        pos += path_len;

        entry.mode = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        entry.size = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        entry.mtime_ns = std.mem.readInt(i128, data[pos..][0..16], .little);
        pos += 16;

        const chunk_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const hashes = try allocator.alloc(Hash, chunk_count);
        for (hashes) |*h| {
            @memcpy(h, data[pos..][0..32]);
            pos += 32;
        }
        entry.chunk_hashes = hashes;
    }

    return entries;
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []TreeEntry) void {
    for (entries) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.chunk_hashes);
    }
    allocator.free(entries);
}
