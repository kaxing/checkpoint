const std = @import("std");
const c = @cImport(@cInclude("zstd.h"));

pub const Error = error{
    ZstdError,
    OutOfMemory,
};

pub fn compress(allocator: std.mem.Allocator, src: []const u8) Error![]u8 {
    const bound = c.ZSTD_compressBound(src.len);
    const dst = allocator.alloc(u8, bound) catch return error.OutOfMemory;

    const result = c.ZSTD_compress(dst.ptr, dst.len, src.ptr, src.len, 1);
    if (c.ZSTD_isError(result) != 0) {
        allocator.free(dst);
        return error.ZstdError;
    }

    // Realloc to exact size so caller can free the returned slice
    const exact = allocator.alloc(u8, result) catch {
        allocator.free(dst);
        return error.OutOfMemory;
    };
    @memcpy(exact, dst[0..result]);
    allocator.free(dst);
    return exact;
}

pub fn decompress(allocator: std.mem.Allocator, src: []const u8, raw_len: usize) Error![]u8 {
    const dst = allocator.alloc(u8, raw_len) catch return error.OutOfMemory;

    const result = c.ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len);
    if (c.ZSTD_isError(result) != 0) {
        allocator.free(dst);
        return error.ZstdError;
    }

    return dst;
}
