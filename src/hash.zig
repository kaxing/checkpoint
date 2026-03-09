const std = @import("std");

pub const Hash = [32]u8;

pub fn hashBytes(data: []const u8) Hash {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(data);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn eql(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn toHex(h: Hash) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (h, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

/// HashMap context for Hash keys — use first 8 bytes as hash (already random from BLAKE3).
pub const HashContext = struct {
    pub fn hash(_: HashContext, key: Hash) u64 {
        return std.mem.readInt(u64, key[0..8], .little);
    }
    pub fn eql(_: HashContext, a: Hash, b: Hash) bool {
        return std.mem.eql(u8, &a, &b);
    }
};
