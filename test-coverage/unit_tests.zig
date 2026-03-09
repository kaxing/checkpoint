const std = @import("std");
const hash_mod = @import("hash");
const chunker_mod = @import("chunker");
const tree_mod = @import("tree");
const comp = @import("compress");

// ── Hash tests ──

test "hashBytes deterministic" {
    const h1 = hash_mod.hashBytes("hello world");
    const h2 = hash_mod.hashBytes("hello world");
    try std.testing.expect(hash_mod.eql(h1, h2));
}

test "hashBytes different inputs differ" {
    const h1 = hash_mod.hashBytes("hello");
    const h2 = hash_mod.hashBytes("world");
    try std.testing.expect(!hash_mod.eql(h1, h2));
}

test "hashBytes empty input" {
    const h = hash_mod.hashBytes("");
    // Should produce a valid 32-byte hash (BLAKE3 empty hash)
    try std.testing.expectEqual(@as(usize, 32), h.len);
}

test "toHex produces 64 chars" {
    const h = hash_mod.hashBytes("test");
    const hex = hash_mod.toHex(h);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "HashContext consistent" {
    const ctx = hash_mod.HashContext{};
    const h1 = hash_mod.hashBytes("test");
    const v1 = ctx.hash(h1);
    const v2 = ctx.hash(h1);
    try std.testing.expectEqual(v1, v2);
    try std.testing.expect(ctx.eql(h1, h1));
}

// ── Compress tests ──

test "compress decompress roundtrip" {
    const allocator = std.testing.allocator;
    const original = "The quick brown fox jumps over the lazy dog. " ** 10;

    const compressed = try comp.compress(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try comp.decompress(allocator, compressed, original.len);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compress decompress empty" {
    const allocator = std.testing.allocator;
    const original = "";

    const compressed = try comp.compress(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try comp.decompress(allocator, compressed, 0);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "compress decompress binary data" {
    const allocator = std.testing.allocator;
    var original: [1024]u8 = undefined;
    // Fill with pseudo-random bytes
    var rng = std.Random.DefaultPrng.init(42);
    rng.fill(&original);

    const compressed = try comp.compress(allocator, &original);
    defer allocator.free(compressed);

    const decompressed = try comp.decompress(allocator, compressed, original.len);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &original, decompressed);
}

// ── Chunker tests ──

test "chunker deterministic" {
    const data = "abcdefgh" ** 2000;
    var cdc1 = chunker_mod.FastCDC.init(data, .{});
    var cdc2 = chunker_mod.FastCDC.init(data, .{});

    while (true) {
        const c1 = cdc1.next();
        const c2 = cdc2.next();
        if (c1 == null and c2 == null) break;
        try std.testing.expect(c1 != null and c2 != null);
        try std.testing.expectEqualSlices(u8, c1.?.data, c2.?.data);
        try std.testing.expectEqual(c1.?.offset, c2.?.offset);
    }
}

test "chunker covers all data" {
    const data = "x" ** 50000;
    var cdc = chunker_mod.FastCDC.init(data, .{});
    var total: usize = 0;
    var prev_end: usize = 0;

    while (cdc.next()) |chunk| {
        try std.testing.expectEqual(prev_end, chunk.offset);
        total += chunk.data.len;
        prev_end = chunk.offset + chunk.data.len;
    }
    try std.testing.expectEqual(data.len, total);
}

test "chunker respects min size" {
    const data = "y" ** 50000;
    var cdc = chunker_mod.FastCDC.init(data, .{});
    var count: usize = 0;

    while (cdc.next()) |chunk| {
        count += 1;
        // Last chunk may be smaller than min
        if (cdc.pos < data.len) {
            try std.testing.expect(chunk.data.len >= 2048);
        }
    }
    try std.testing.expect(count > 0);
}

test "chunker respects max size" {
    const data = "z" ** 200000;
    var cdc = chunker_mod.FastCDC.init(data, .{});

    while (cdc.next()) |chunk| {
        try std.testing.expect(chunk.data.len <= 65536);
    }
}

test "chunker small input returns single chunk" {
    const data = "small";
    var cdc = chunker_mod.FastCDC.init(data, .{});
    const chunk = cdc.next();
    try std.testing.expect(chunk != null);
    try std.testing.expectEqualSlices(u8, data, chunk.?.data);
    try std.testing.expect(cdc.next() == null);
}

test "chunker empty input" {
    var cdc = chunker_mod.FastCDC.init("", .{});
    try std.testing.expect(cdc.next() == null);
}

// ── Tree serialization tests ──

test "tree serialize deserialize roundtrip" {
    const allocator = std.testing.allocator;

    const h1 = hash_mod.hashBytes("chunk1");
    const h2 = hash_mod.hashBytes("chunk2");
    const h3 = hash_mod.hashBytes("chunk3");

    const hashes1 = try allocator.dupe(hash_mod.Hash, &.{ h1, h2 });
    defer allocator.free(hashes1);
    const hashes2 = try allocator.dupe(hash_mod.Hash, &.{h3});
    defer allocator.free(hashes2);

    const entries = [_]tree_mod.TreeEntry{
        .{ .path = "dir/file1.txt", .mode = 0o100644, .size = 1234, .mtime_ns = 999888777, .chunk_hashes = hashes1 },
        .{ .path = "file2.txt", .mode = 0o100755, .size = 5678, .mtime_ns = -100, .chunk_hashes = hashes2 },
    };

    const data = try tree_mod.serialize(allocator, &entries);
    defer allocator.free(data);

    const decoded = try tree_mod.deserialize(allocator, data);
    defer tree_mod.freeEntries(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);

    try std.testing.expectEqualSlices(u8, "dir/file1.txt", decoded[0].path);
    try std.testing.expectEqual(@as(u16, 0o100644), decoded[0].mode);
    try std.testing.expectEqual(@as(u64, 1234), decoded[0].size);
    try std.testing.expectEqual(@as(i128, 999888777), decoded[0].mtime_ns);
    try std.testing.expectEqual(@as(usize, 2), decoded[0].chunk_hashes.len);
    try std.testing.expect(hash_mod.eql(decoded[0].chunk_hashes[0], h1));
    try std.testing.expect(hash_mod.eql(decoded[0].chunk_hashes[1], h2));

    try std.testing.expectEqualSlices(u8, "file2.txt", decoded[1].path);
    try std.testing.expectEqual(@as(u16, 0o100755), decoded[1].mode);
    try std.testing.expectEqual(@as(u64, 5678), decoded[1].size);
    try std.testing.expectEqual(@as(i128, -100), decoded[1].mtime_ns);
    try std.testing.expectEqual(@as(usize, 1), decoded[1].chunk_hashes.len);
    try std.testing.expect(hash_mod.eql(decoded[1].chunk_hashes[0], h3));
}

test "tree serialize deserialize empty" {
    const allocator = std.testing.allocator;
    const entries = [_]tree_mod.TreeEntry{};

    const data = try tree_mod.serialize(allocator, &entries);
    defer allocator.free(data);

    const decoded = try tree_mod.deserialize(allocator, data);
    defer tree_mod.freeEntries(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "tree serialize deserialize no chunks" {
    const allocator = std.testing.allocator;
    const entries = [_]tree_mod.TreeEntry{
        .{ .path = "empty.txt", .mode = 0o100644, .size = 0, .mtime_ns = 0, .chunk_hashes = &.{} },
    };

    const data = try tree_mod.serialize(allocator, &entries);
    defer allocator.free(data);

    const decoded = try tree_mod.deserialize(allocator, data);
    defer tree_mod.freeEntries(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(u8, "empty.txt", decoded[0].path);
    try std.testing.expectEqual(@as(usize, 0), decoded[0].chunk_hashes.len);
}

// ── End-to-end: chunk + hash + compress + pack roundtrip ──

test "chunk hash compress decompress roundtrip" {
    const allocator = std.testing.allocator;
    const original = "Hello, world! This is a test of the chunking pipeline. " ** 100;

    var cdc = chunker_mod.FastCDC.init(original, .{});
    var reconstructed: std.ArrayList(u8) = .{};
    defer reconstructed.deinit(allocator);

    while (cdc.next()) |chunk| {
        const h = hash_mod.hashBytes(chunk.data);
        const compressed = try comp.compress(allocator, chunk.data);
        defer allocator.free(compressed);

        const decompressed = try comp.decompress(allocator, compressed, @intCast(chunk.data.len));
        defer allocator.free(decompressed);

        // Verify hash matches
        const h2 = hash_mod.hashBytes(decompressed);
        try std.testing.expect(hash_mod.eql(h, h2));

        try reconstructed.appendSlice(allocator, decompressed);
    }

    try std.testing.expectEqualSlices(u8, original, reconstructed.items);
}
