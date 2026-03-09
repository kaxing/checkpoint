const std = @import("std");

/// A chunk produced by any chunking strategy.
pub const Chunk = struct {
    data: []const u8,
    offset: usize,
};

// ---------- Fixed-size chunker ----------

pub const FixedChunker = struct {
    data: []const u8,
    chunk_size: usize,
    pos: usize,

    pub fn init(data: []const u8, chunk_size: usize) FixedChunker {
        return .{ .data = data, .chunk_size = chunk_size, .pos = 0 };
    }

    pub fn next(self: *FixedChunker) ?Chunk {
        if (self.pos >= self.data.len) return null;
        const end = @min(self.pos + self.chunk_size, self.data.len);
        const chunk = Chunk{ .data = self.data[self.pos..end], .offset = self.pos };
        self.pos = end;
        return chunk;
    }
};

// ---------- FastCDC chunker ----------
//
// Based on the FastCDC algorithm (Xia et al., 2016).
// Uses a Gear hash for fast rolling hash with normalized chunking.

pub const FastCDC = struct {
    data: []const u8,
    pos: usize,
    min_size: usize,
    avg_size: usize,
    max_size: usize,
    mask_s: u64, // "small" mask — harder to match, used below avg
    mask_l: u64, // "large" mask — easier to match, used above avg

    pub const Params = struct {
        min_size: usize = 2048,
        avg_size: usize = 8192,
        max_size: usize = 65536,
    };

    pub fn init(data: []const u8, params: Params) FastCDC {
        // mask_s has more bits set → harder to hit → chunks tend toward avg
        // mask_l has fewer bits set → easier to hit → prevents very large chunks
        const bits_s = std.math.log2(params.avg_size);
        const bits_l = bits_s - 2;
        const mask_s = (@as(u64, 1) << @intCast(bits_s)) - 1;
        const mask_l = (@as(u64, 1) << @intCast(bits_l)) - 1;
        return .{
            .data = data,
            .pos = 0,
            .min_size = params.min_size,
            .avg_size = params.avg_size,
            .max_size = params.max_size,
            .mask_s = mask_s,
            .mask_l = mask_l,
        };
    }

    pub fn next(self: *FastCDC) ?Chunk {
        if (self.pos >= self.data.len) return null;

        const remaining = self.data.len - self.pos;
        if (remaining <= self.min_size) {
            const chunk = Chunk{ .data = self.data[self.pos..], .offset = self.pos };
            self.pos = self.data.len;
            return chunk;
        }

        const max_end = self.pos + @min(remaining, self.max_size);
        const avg_end = self.pos + @min(remaining, self.avg_size);

        var fp: u64 = 0;
        var i = self.pos + self.min_size;

        // Phase 1: below average, use stricter mask
        while (i < avg_end) : (i += 1) {
            fp = (fp << 1) +% gear_table[self.data[i]];
            if ((fp & self.mask_s) == 0) {
                const chunk = Chunk{ .data = self.data[self.pos..i], .offset = self.pos };
                self.pos = i;
                return chunk;
            }
        }

        // Phase 2: above average, use relaxed mask
        while (i < max_end) : (i += 1) {
            fp = (fp << 1) +% gear_table[self.data[i]];
            if ((fp & self.mask_l) == 0) {
                const chunk = Chunk{ .data = self.data[self.pos..i], .offset = self.pos };
                self.pos = i;
                return chunk;
            }
        }

        // Hit max size
        const chunk = Chunk{ .data = self.data[self.pos..max_end], .offset = self.pos };
        self.pos = max_end;
        return chunk;
    }
};

// Gear hash lookup table — pre-computed random values for each byte.
// Generated deterministically from a simple PRNG seeded with a constant.
const gear_table: [256]u64 = blk: {
    var table: [256]u64 = undefined;
    var state: u64 = 0x123456789abcdef0;
    for (0..256) |i| {
        // SplitMix64
        state +%= 0x9e3779b97f4a7c15;
        var z = state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        z = z ^ (z >> 31);
        table[i] = z;
    }
    break :blk table;
};
