const std = @import("std");
const Hash = @import("hash.zig").Hash;

const MAGIC = "CKP\x01";

pub const Manifest = struct {
    id: u32,
    timestamp: u64, // unix seconds UTC
    file_count: u32,
    name: []const u8, // empty if unnamed
    tree_hash: Hash,
};

pub fn write(dir: std.fs.Dir, m: Manifest) !void {
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch unreachable;

    const file = try dir.createFile(filename, .{});
    defer file.close();

    // Build the entire manifest in a buffer and write at once
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    @memcpy(buf[pos..][0..4], MAGIC);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little); // version
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], m.id, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], m.timestamp, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], m.file_count, .little);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(m.name.len), .little);
    pos += 2;
    if (m.name.len > 0) {
        @memcpy(buf[pos..][0..m.name.len], m.name);
        pos += m.name.len;
    }
    @memcpy(buf[pos..][0..32], &m.tree_hash);
    pos += 32;

    try file.writeAll(buf[0..pos]);
}

pub fn read(allocator: std.mem.Allocator, dir: std.fs.Dir, id: u32) !Manifest {
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;

    const file = dir.openFile(filename, .{}) catch |err| return err;
    defer file.close();

    var buf: [512]u8 = undefined;
    const n = try file.pread(&buf, 0);
    if (n < 58) return error.InvalidManifest; // minimum size: 4+4+4+8+4+2+0+32 = 58

    var pos: usize = 0;

    // Magic
    if (!std.mem.eql(u8, buf[0..4], MAGIC)) return error.InvalidManifest;
    pos += 4;

    const version = std.mem.readInt(u32, buf[pos..][0..4], .little);
    if (version != 1) return error.UnsupportedVersion;
    pos += 4;

    var m: Manifest = undefined;
    m.id = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    m.timestamp = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    m.file_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;

    const name_len = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    if (name_len > 0) {
        m.name = try allocator.dupe(u8, buf[pos..][0..name_len]);
        pos += name_len;
    } else {
        m.name = "";
    }

    @memcpy(&m.tree_hash, buf[pos..][0..32]);
    return m;
}

pub fn readHead(dir: std.fs.Dir) !?u32 {
    const file = dir.openFile("HEAD", .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = try file.pread(&buf, 0);
    if (n == 0) return null;

    return std.fmt.parseInt(u32, std.mem.trimRight(u8, buf[0..n], "\n \t"), 10) catch return error.InvalidHead;
}

pub fn writeHead(dir: std.fs.Dir, id: u32) !void {
    var buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable;

    const tmp = try dir.createFile("HEAD.tmp", .{});
    try tmp.writeAll(content);
    tmp.close();

    try dir.rename("HEAD.tmp", "HEAD");
}
