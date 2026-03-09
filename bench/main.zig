const std = @import("std");
const chunker = @import("chunker.zig");

const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

// ── Configuration ──

const DATA_SIZE = 10 * 1024 * 1024; // 10 MB synthetic data
const WARMUP_ITERS = 1;
const BENCH_ITERS = 3;

const ChunkerKind = enum { fixed_4k, fixed_8k, fixed_16k, fastcdc };
const HashKind = enum { blake3, sha256 };

const Config = struct {
    chunker_kind: ChunkerKind,
    hash_kind: HashKind,
};

// ── Synthetic data generation ──

fn generateSourceLikeData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const buf = try allocator.alloc(u8, size);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    const lines = [_][]const u8{
        "fn processItem(item: *const Item) !void {\n",
        "    const result = try item.validate();\n",
        "    if (result.isValid()) {\n",
        "        try self.store.put(item.key, item.value);\n",
        "    } else {\n",
        "        log.warn(\"invalid item: {}\", .{item.key});\n",
        "    }\n",
        "}\n",
        "\n",
        "pub const Config = struct {\n",
        "    max_retries: u32 = 3,\n",
        "    timeout_ms: u64 = 5000,\n",
        "    buffer_size: usize = 4096,\n",
        "};\n",
        "\n",
        "test \"basic functionality\" {\n",
        "    const allocator = std.testing.allocator;\n",
        "    var list = std.ArrayList(u8).init(allocator);\n",
        "    defer list.deinit();\n",
        "    try list.appendSlice(\"hello world\");\n",
        "    try std.testing.expectEqualStrings(\"hello world\", list.items);\n",
        "}\n",
        "\n",
        "// TODO: implement caching layer\n",
        "// FIXME: handle edge case for empty input\n",
        "const VERSION = \"0.1.0\";\n",
        "\n",
    };

    var pos: usize = 0;
    while (pos < size) {
        const idx = rand.uintLessThan(usize, lines.len);
        const line = lines[idx];
        const n = @min(line.len, size - pos);
        @memcpy(buf[pos..][0..n], line[0..n]);
        pos += n;
    }

    return buf;
}

/// Simulate realistic edits: modify a few contiguous regions (~1% of data)
fn applySmallEdits(data: []u8) void {
    var prng = std.Random.DefaultPrng.init(0xcafebabe);
    const rand = prng.random();

    // 10 contiguous edit regions, each ~0.1% of data
    const region_size = data.len / 1000;
    for (0..10) |_| {
        const start = rand.uintLessThan(usize, data.len - region_size);
        for (0..region_size) |j| {
            data[start + j] = rand.int(u8);
        }
    }
}

// ── Hashing ──

fn hashChunk(data: []const u8, kind: HashKind) [32]u8 {
    switch (kind) {
        .blake3 => {
            var h = Blake3.init(.{});
            h.update(data);
            var out: [32]u8 = undefined;
            h.final(&out);
            return out;
        },
        .sha256 => {
            var h = Sha256.init(.{});
            h.update(data);
            return h.finalResult();
        },
    }
}

// ── Dedup measurement ──

const HashSet = std.AutoHashMap([32]u8, void);

fn collectHashes(
    allocator: std.mem.Allocator,
    data: []const u8,
    ck: ChunkerKind,
    hk: HashKind,
) !struct { set: HashSet, count: usize } {
    var set = HashSet.init(allocator);
    var count: usize = 0;

    switch (ck) {
        .fixed_4k => {
            var c = chunker.FixedChunker.init(data, 4096);
            while (c.next()) |ch| {
                try set.put(hashChunk(ch.data, hk), {});
                count += 1;
            }
        },
        .fixed_8k => {
            var c = chunker.FixedChunker.init(data, 8192);
            while (c.next()) |ch| {
                try set.put(hashChunk(ch.data, hk), {});
                count += 1;
            }
        },
        .fixed_16k => {
            var c = chunker.FixedChunker.init(data, 16384);
            while (c.next()) |ch| {
                try set.put(hashChunk(ch.data, hk), {});
                count += 1;
            }
        },
        .fastcdc => {
            var c = chunker.FastCDC.init(data, .{});
            while (c.next()) |ch| {
                try set.put(hashChunk(ch.data, hk), {});
                count += 1;
            }
        },
    }

    return .{ .set = set, .count = count };
}

// ── Benchmark runner ──

const BenchResult = struct {
    save_mbps: f64,
    restore_mbps: f64,
    avg_chunk_size: f64,
    dedup_ratio: f64,
};

fn benchConfig(
    allocator: std.mem.Allocator,
    data1: []const u8,
    data2: []const u8,
    config: Config,
) !BenchResult {
    // Save throughput: chunk + hash
    for (0..WARMUP_ITERS) |_| {
        _ = runSave(data1, config);
    }

    var save_ns: u64 = 0;
    var chunk_count: usize = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = try std.time.Timer.start();
        chunk_count = runSave(data1, config);
        save_ns += timer.read();
    }
    const save_mbps = calcMbps(DATA_SIZE * BENCH_ITERS, save_ns);

    // Restore throughput: verify hashes (simulates decompress + verify)
    for (0..WARMUP_ITERS) |_| {
        _ = runRestore(data1, config);
    }

    var restore_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = try std.time.Timer.start();
        _ = runRestore(data1, config);
        restore_ns += timer.read();
    }
    const restore_mbps = calcMbps(DATA_SIZE * BENCH_ITERS, restore_ns);

    // Avg chunk size
    const avg_chunk_size = @as(f64, @floatFromInt(DATA_SIZE)) /
        @as(f64, @floatFromInt(chunk_count));

    // Dedup ratio
    var r1 = try collectHashes(allocator, data1, config.chunker_kind, config.hash_kind);
    defer r1.set.deinit();
    var r2 = try collectHashes(allocator, data2, config.chunker_kind, config.hash_kind);
    defer r2.set.deinit();

    const total_chunks = r1.count + r2.count;
    var it = r2.set.iterator();
    while (it.next()) |entry| {
        try r1.set.put(entry.key_ptr.*, {});
    }
    const unique_chunks = r1.set.count();
    const dedup_ratio = @as(f64, @floatFromInt(unique_chunks)) /
        @as(f64, @floatFromInt(total_chunks));

    return .{
        .save_mbps = save_mbps,
        .restore_mbps = restore_mbps,
        .avg_chunk_size = avg_chunk_size,
        .dedup_ratio = dedup_ratio,
    };
}

fn runSave(data: []const u8, config: Config) usize {
    var count: usize = 0;
    switch (config.chunker_kind) {
        .fixed_4k => {
            var c = chunker.FixedChunker.init(data, 4096);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fixed_8k => {
            var c = chunker.FixedChunker.init(data, 8192);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fixed_16k => {
            var c = chunker.FixedChunker.init(data, 16384);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fastcdc => {
            var c = chunker.FastCDC.init(data, .{});
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
    }
    return count;
}

fn runRestore(data: []const u8, config: Config) usize {
    // Simulates restore: re-chunk and verify hashes
    var count: usize = 0;
    switch (config.chunker_kind) {
        .fixed_4k => {
            var c = chunker.FixedChunker.init(data, 4096);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fixed_8k => {
            var c = chunker.FixedChunker.init(data, 8192);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fixed_16k => {
            var c = chunker.FixedChunker.init(data, 16384);
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
        .fastcdc => {
            var c = chunker.FastCDC.init(data, .{});
            while (c.next()) |ch| {
                _ = hashChunk(ch.data, config.hash_kind);
                count += 1;
            }
        },
    }
    return count;
}

fn calcMbps(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const bytes_f: f64 = @floatFromInt(bytes);
    const secs = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    return (bytes_f / (1024.0 * 1024.0)) / secs;
}

// ── Output ──

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
}

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    print("\n=== Checkpoint Algorithm Benchmark ===\n", .{});
    print("Data size: {d} MB, Iterations: {d}\n\n", .{ DATA_SIZE / (1024 * 1024), BENCH_ITERS });

    print("Generating synthetic data...\n", .{});
    const data1 = try generateSourceLikeData(allocator, DATA_SIZE);
    defer allocator.free(data1);

    const data2 = try allocator.alloc(u8, DATA_SIZE);
    defer allocator.free(data2);
    @memcpy(data2, data1);
    applySmallEdits(data2);

    print("Running benchmarks...\n\n", .{});

    // Header
    print("{s: <12} {s: <6}  {s: >10} {s: >10} {s: >10} {s: >7}\n", .{
        "Chunker", "Hash", "Save MB/s", "Rest MB/s", "Avg Chunk", "Dedup",
    });
    print("{s}\n", .{"-" ** 62});

    const chunker_kinds = [_]ChunkerKind{ .fixed_4k, .fixed_8k, .fixed_16k, .fastcdc };
    const hash_kinds = [_]HashKind{ .blake3, .sha256 };

    for (chunker_kinds) |ck| {
        for (hash_kinds) |hk| {
            const config = Config{ .chunker_kind = ck, .hash_kind = hk };
            const result = try benchConfig(allocator, data1, data2, config);

            const ck_name: []const u8 = switch (ck) {
                .fixed_4k => "fixed-4K",
                .fixed_8k => "fixed-8K",
                .fixed_16k => "fixed-16K",
                .fastcdc => "fastcdc",
            };
            const hk_name: []const u8 = switch (hk) {
                .blake3 => "blake3",
                .sha256 => "sha256",
            };

            print("{s: <12} {s: <6}  {d: >10.1} {d: >10.1} {d: >9.0}B {d: >6.1}%\n", .{
                ck_name,
                hk_name,
                result.save_mbps,
                result.restore_mbps,
                result.avg_chunk_size,
                result.dedup_ratio * 100,
            });
        }
    }

    print("\nNotes:\n", .{});
    print("  - Dedup: unique/total chunks across 2 snapshots w/ 1% edits (lower=better)\n", .{});
    print("  - Compression not benchmarked: Zig 0.15 stdlib deflate compressor is incomplete,\n", .{});
    print("    zstd has decompressor only. Will use C libzstd binding for production.\n\n", .{});
}
