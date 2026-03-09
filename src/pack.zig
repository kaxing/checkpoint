const std = @import("std");
const hash_mod = @import("hash.zig");
const comp = @import("compress.zig");

const Hash = hash_mod.Hash;
const HashContext = hash_mod.HashContext;

const ENTRY_HEADER_SIZE = 40;

pub const PackEntry = struct {
    offset: u64,
    compressed_len: u32,
    raw_len: u32,
};

pub const Pack = struct {
    file: std.fs.File,
    index: std.HashMap(Hash, PackEntry, HashContext, 80),
    allocator: std.mem.Allocator,
    write_pos: u64, // track position to avoid stat() on every write

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) !Pack {
        const file = dir.createFile("pack.dat", .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        }) catch |err| return err;

        var pack = Pack{
            .file = file,
            .index = std.HashMap(Hash, PackEntry, HashContext, 80).init(allocator),
            .allocator = allocator,
            .write_pos = 0,
        };

        try pack.buildIndex();
        return pack;
    }

    pub fn deinit(self: *Pack) void {
        self.file.close();
        self.index.deinit();
    }

    fn buildIndex(self: *Pack) !void {
        const stat = try self.file.stat();
        const file_size = stat.size;
        var pos: u64 = 0;

        while (pos + ENTRY_HEADER_SIZE <= file_size) {
            var header_buf: [ENTRY_HEADER_SIZE]u8 = undefined;
            const n = try self.file.pread(&header_buf, pos);
            if (n < ENTRY_HEADER_SIZE) break;

            const h: Hash = header_buf[0..32].*;
            const compressed_len = std.mem.readInt(u32, header_buf[32..36], .little);
            const raw_len = std.mem.readInt(u32, header_buf[36..40], .little);

            try self.index.put(h, .{
                .offset = pos,
                .compressed_len = compressed_len,
                .raw_len = raw_len,
            });

            pos += ENTRY_HEADER_SIZE + compressed_len;
        }

        self.write_pos = pos;
    }

    pub fn hasChunk(self: *Pack, h: Hash) bool {
        return self.index.get(h) != null;
    }

    pub fn writeChunk(self: *Pack, h: Hash, data: []const u8) !void {
        if (self.hasChunk(h)) return;

        const compressed = try comp.compress(self.allocator, data);
        defer self.allocator.free(compressed);

        try self.appendEntry(h, compressed, @intCast(data.len));
    }

    pub fn writeChunkPreCompressed(self: *Pack, h: Hash, compressed: []const u8, raw_len: u32) !void {
        if (self.hasChunk(h)) return;
        try self.appendEntry(h, compressed, raw_len);
    }

    fn appendEntry(self: *Pack, h: Hash, compressed: []const u8, raw_len: u32) !void {
        const offset = self.write_pos;
        try self.file.seekTo(offset);

        var header: [ENTRY_HEADER_SIZE]u8 = undefined;
        @memcpy(header[0..32], &h);
        std.mem.writeInt(u32, header[32..36], @intCast(compressed.len), .little);
        std.mem.writeInt(u32, header[36..40], raw_len, .little);
        try self.file.writeAll(&header);
        try self.file.writeAll(compressed);

        self.write_pos = offset + ENTRY_HEADER_SIZE + compressed.len;

        try self.index.put(h, .{
            .offset = offset,
            .compressed_len = @intCast(compressed.len),
            .raw_len = raw_len,
        });
    }

    pub fn getEntry(self: *Pack, h: Hash) ?PackEntry {
        return self.index.get(h);
    }

    pub fn readChunk(self: *Pack, h: Hash) ![]u8 {
        const entry = self.index.get(h) orelse return error.ChunkNotFound;

        const compressed = try self.allocator.alloc(u8, entry.compressed_len);
        defer self.allocator.free(compressed);

        const n = try self.file.pread(compressed, entry.offset + ENTRY_HEADER_SIZE);
        if (n < entry.compressed_len) return error.UnexpectedEof;

        const raw = try comp.decompress(self.allocator, compressed, entry.raw_len);

        const actual = hash_mod.hashBytes(raw);
        if (!std.mem.eql(u8, &actual, &h)) {
            self.allocator.free(raw);
            return error.HashMismatch;
        }

        return raw;
    }
};
