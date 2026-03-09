const std = @import("std");
const hash_mod = @import("hash.zig");
const chunker_mod = @import("chunker.zig");
const pack_mod = @import("pack.zig");
const tree_mod = @import("tree.zig");
const manifest_mod = @import("manifest.zig");
const walker_mod = @import("walker.zig");
const comp = @import("compress.zig");

const Hash = hash_mod.Hash;
const CHECKPOINT_DIR = ".checkpoint-files";
const MAX_SNAPSHOTS = 50;

const FileResult = struct {
    chunks: []ChunkResult,
    failed: bool,
};

const ChunkResult = struct {
    hash: Hash,
    compressed: []u8,
    raw_len: u32,
};

pub const Repo = struct {
    allocator: std.mem.Allocator,
    root: std.fs.Dir,
    cp_dir: std.fs.Dir,
    manifests_dir: std.fs.Dir,
    pack: pack_mod.Pack,

    pub fn open(allocator: std.mem.Allocator, root: std.fs.Dir) !Repo {
        var cp_dir = root.openDir(CHECKPOINT_DIR, .{}) catch |err| {
            if (err == error.FileNotFound) return error.NotInitialized;
            return err;
        };
        errdefer cp_dir.close();

        const manifests_dir = try cp_dir.openDir("manifests", .{});
        const pack = try pack_mod.Pack.init(allocator, cp_dir);

        return .{
            .allocator = allocator,
            .root = root,
            .cp_dir = cp_dir,
            .manifests_dir = manifests_dir,
            .pack = pack,
        };
    }

    pub fn create(allocator: std.mem.Allocator, root: std.fs.Dir) !Repo {
        root.makeDir(CHECKPOINT_DIR) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        var cp_dir = try root.openDir(CHECKPOINT_DIR, .{});
        errdefer cp_dir.close();

        cp_dir.makeDir("manifests") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        const manifests_dir = try cp_dir.openDir("manifests", .{});
        const pack = try pack_mod.Pack.init(allocator, cp_dir);

        return .{
            .allocator = allocator,
            .root = root,
            .cp_dir = cp_dir,
            .manifests_dir = manifests_dir,
            .pack = pack,
        };
    }

    pub fn deinit(self: *Repo) void {
        self.pack.deinit();
        self.manifests_dir.close();
        self.cp_dir.close();
    }

    // ── Save ──

    pub fn save(self: *Repo, name: ?[]const u8) !u32 {
        var walker = try walker_mod.Walker.init(self.allocator, self.root);
        defer walker.deinit();
        const walk_entries = try walker.walk(self.root);
        defer {
            for (walk_entries) |e| self.allocator.free(e.path);
            self.allocator.free(walk_entries);
        }

        // Load previous tree for mtime+size change detection
        const prev_tree = self.loadPreviousTree();
        defer if (prev_tree) |pt| tree_mod.freeEntries(self.allocator, pt);

        // Parallel: read + chunk + hash + compress changed files
        const file_results = try self.allocator.alloc(FileResult, walk_entries.len);
        defer {
            for (file_results) |fr| {
                for (fr.chunks) |cr| self.allocator.free(cr.compressed);
                self.allocator.free(fr.chunks);
            }
            self.allocator.free(file_results);
        }

        const reused = try self.allocator.alloc(?[]const Hash, walk_entries.len);
        defer self.allocator.free(reused);

        for (file_results, 0..) |*fr, i| {
            fr.* = .{ .chunks = &.{}, .failed = true };
            reused[i] = null;
        }

        {
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = self.allocator });
            defer pool.deinit();

            var wg: std.Thread.WaitGroup = .{};
            for (walk_entries, 0..) |we, i| {
                if (prev_tree) |pt| {
                    if (findEntry(pt, we.path)) |prev| {
                        if (prev.size == we.size and prev.mtime_ns == we.mtime_ns) {
                            reused[i] = prev.chunk_hashes;
                            continue;
                        }
                    }
                }
                pool.spawnWg(&wg, processFileForSave, .{
                    self.allocator, self.root, we.path, &file_results[i],
                });
            }
            wg.wait();
        }

        // Sequential: write new chunks to pack + build tree
        var tree_entries = try self.allocator.alloc(tree_mod.TreeEntry, walk_entries.len);
        defer {
            for (tree_entries, 0..) |te, i| {
                if (reused[i] == null and te.chunk_hashes.len > 0)
                    self.allocator.free(te.chunk_hashes);
            }
            self.allocator.free(tree_entries);
        }

        for (walk_entries, 0..) |we, i| {
            if (reused[i]) |prev_hashes| {
                tree_entries[i] = .{
                    .path = we.path, .mode = we.mode, .size = we.size,
                    .mtime_ns = we.mtime_ns, .chunk_hashes = prev_hashes,
                };
                continue;
            }

            const fr = file_results[i];
            if (fr.failed) {
                tree_entries[i] = .{
                    .path = we.path, .mode = we.mode, .size = 0,
                    .mtime_ns = we.mtime_ns, .chunk_hashes = &.{},
                };
                continue;
            }

            const hashes = try self.allocator.alloc(Hash, fr.chunks.len);
            for (fr.chunks, 0..) |cr, j| {
                hashes[j] = cr.hash;
                try self.pack.writeChunkPreCompressed(cr.hash, cr.compressed, cr.raw_len);
            }

            tree_entries[i] = .{
                .path = we.path, .mode = we.mode, .size = we.size,
                .mtime_ns = we.mtime_ns, .chunk_hashes = hashes,
            };
        }

        const tree_data = try tree_mod.serialize(self.allocator, tree_entries);
        defer self.allocator.free(tree_data);
        const tree_hash = hash_mod.hashBytes(tree_data);
        try self.pack.writeChunk(tree_hash, tree_data);

        const head = try manifest_mod.readHead(self.cp_dir);
        const next_id: u32 = if (head) |h| h + 1 else 1;

        try manifest_mod.write(self.manifests_dir, .{
            .id = next_id,
            .timestamp = @intCast(std.time.timestamp()),
            .file_count = @intCast(walk_entries.len),
            .name = name orelse "",
            .tree_hash = tree_hash,
        });

        try manifest_mod.writeHead(self.cp_dir, next_id);

        if (next_id > MAX_SNAPSHOTS) self.prune(next_id) catch {};

        return next_id;
    }

    fn processFileForSave(allocator: std.mem.Allocator, root: std.fs.Dir, path: []const u8, result: *FileResult) void {
        const file = root.openFile(path, .{}) catch return;
        defer file.close();
        const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return;
        defer allocator.free(data);

        var chunk_count: usize = 0;
        {
            var cdc = chunker_mod.FastCDC.init(data, .{});
            while (cdc.next()) |_| chunk_count += 1;
        }

        const chunks = allocator.alloc(ChunkResult, chunk_count) catch return;
        var idx: usize = 0;
        var cdc = chunker_mod.FastCDC.init(data, .{});
        while (cdc.next()) |chunk| {
            const h = hash_mod.hashBytes(chunk.data);
            const compressed = comp.compress(allocator, chunk.data) catch {
                for (chunks[0..idx]) |cr| allocator.free(cr.compressed);
                allocator.free(chunks);
                return;
            };
            chunks[idx] = .{ .hash = h, .compressed = compressed, .raw_len = @intCast(chunk.data.len) };
            idx += 1;
        }
        result.* = .{ .chunks = chunks, .failed = false };
    }

    // ── Restore ──

    pub fn restore(self: *Repo, target_id: ?u32) !void {
        const id = if (target_id) |t| t else (try manifest_mod.readHead(self.cp_dir)) orelse return error.NoSnapshots;

        const m = try manifest_mod.read(self.allocator, self.manifests_dir, id);
        defer if (m.name.len > 0) self.allocator.free(m.name);

        const tree_data = try self.pack.readChunk(m.tree_hash);
        defer self.allocator.free(tree_data);
        const entries = try tree_mod.deserialize(self.allocator, tree_data);
        defer tree_mod.freeEntries(self.allocator, entries);

        // Delete files not in snapshot
        var walker = try walker_mod.Walker.init(self.allocator, self.root);
        defer walker.deinit();
        const current_files = try walker.walk(self.root);
        defer {
            for (current_files) |e| self.allocator.free(e.path);
            self.allocator.free(current_files);
        }

        for (current_files) |cf| {
            if (findEntry(entries, cf.path) == null) {
                self.root.deleteFile(cf.path) catch {};
            }
        }

        // Read all file contents from pack (sequential reads)
        const file_contents = try self.allocator.alloc(?[]u8, entries.len);
        defer {
            for (file_contents) |fc| if (fc) |c| self.allocator.free(c);
            self.allocator.free(file_contents);
        }

        for (entries, 0..) |entry, i| {
            if (entry.chunk_hashes.len == 0) {
                file_contents[i] = try self.allocator.alloc(u8, 0);
                continue;
            }

            var total_size: usize = 0;
            var valid = true;
            for (entry.chunk_hashes) |h| {
                const e = self.pack.getEntry(h) orelse { valid = false; break; };
                total_size += e.raw_len;
            }
            if (!valid) { file_contents[i] = null; continue; }

            const buf = self.allocator.alloc(u8, total_size) catch { file_contents[i] = null; continue; };
            var pos: usize = 0;
            var ok = true;
            for (entry.chunk_hashes) |h| {
                const chunk_data = self.pack.readChunk(h) catch { ok = false; break; };
                defer self.allocator.free(chunk_data);
                @memcpy(buf[pos..][0..chunk_data.len], chunk_data);
                pos += chunk_data.len;
            }
            file_contents[i] = if (ok) buf else blk: { self.allocator.free(buf); break :blk null; };
        }

        // Parallel file writes
        {
            for (entries) |entry| {
                if (std.fs.path.dirname(entry.path)) |dp| self.root.makePath(dp) catch {};
            }

            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = self.allocator });
            defer pool.deinit();

            var wg: std.Thread.WaitGroup = .{};
            for (entries, 0..) |entry, i| {
                if (file_contents[i]) |content|
                    pool.spawnWg(&wg, writeFileTask, .{ self.root, entry.path, content });
            }
            wg.wait();
        }

        self.cleanEmptyDirs() catch {};
    }

    fn writeFileTask(root: std.fs.Dir, path: []const u8, content: []const u8) void {
        const file = root.createFile(path, .{}) catch return;
        defer file.close();
        file.writeAll(content) catch {};
    }

    // ── Diff ──

    pub fn diff(self: *Repo, target_id: ?u32) !DiffResult {
        const id = if (target_id) |t| t else (try manifest_mod.readHead(self.cp_dir)) orelse return error.NoSnapshots;

        const m = try manifest_mod.read(self.allocator, self.manifests_dir, id);
        defer if (m.name.len > 0) self.allocator.free(m.name);

        const tree_data = try self.pack.readChunk(m.tree_hash);
        defer self.allocator.free(tree_data);
        const old_entries = try tree_mod.deserialize(self.allocator, tree_data);

        var walker = try walker_mod.Walker.init(self.allocator, self.root);
        defer walker.deinit();
        const walk_entries = try walker.walk(self.root);

        // Parallel: hash changed files, skip unchanged via mtime+size
        var new_entries = try self.allocator.alloc(tree_mod.TreeEntry, walk_entries.len);

        {
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = self.allocator });
            defer pool.deinit();

            var wg: std.Thread.WaitGroup = .{};
            for (walk_entries, 0..) |we, i| {
                if (findEntry(old_entries, we.path)) |old| {
                    if (old.size == we.size and old.mtime_ns == we.mtime_ns) {
                        // Copy hashes so each tree owns its own memory
                        const hashes_copy = self.allocator.dupe(Hash, old.chunk_hashes) catch &.{};
                        new_entries[i] = .{
                            .path = we.path, .mode = we.mode, .size = we.size,
                            .mtime_ns = we.mtime_ns, .chunk_hashes = hashes_copy,
                        };
                        continue;
                    }
                }
                pool.spawnWg(&wg, processFileForDiff, .{
                    self.allocator, self.root, we, &new_entries[i],
                });
            }
            wg.wait();
        }

        // Merge-walk comparison
        var added: std.ArrayList([]const u8) = .{};
        var removed: std.ArrayList([]const u8) = .{};
        var modified: std.ArrayList([]const u8) = .{};

        var oi: usize = 0;
        var ni: usize = 0;
        while (oi < old_entries.len or ni < new_entries.len) {
            if (oi >= old_entries.len) {
                try added.append(self.allocator, try self.allocator.dupe(u8, new_entries[ni].path));
                ni += 1;
            } else if (ni >= new_entries.len) {
                try removed.append(self.allocator, try self.allocator.dupe(u8, old_entries[oi].path));
                oi += 1;
            } else {
                const cmp = std.mem.order(u8, old_entries[oi].path, new_entries[ni].path);
                switch (cmp) {
                    .lt => { try removed.append(self.allocator, try self.allocator.dupe(u8, old_entries[oi].path)); oi += 1; },
                    .gt => { try added.append(self.allocator, try self.allocator.dupe(u8, new_entries[ni].path)); ni += 1; },
                    .eq => {
                        if (!hashListEqual(old_entries[oi].chunk_hashes, new_entries[ni].chunk_hashes))
                            try modified.append(self.allocator, try self.allocator.dupe(u8, new_entries[ni].path));
                        oi += 1;
                        ni += 1;
                    },
                }
            }
        }

        return .{
            .added = try added.toOwnedSlice(self.allocator),
            .removed = try removed.toOwnedSlice(self.allocator),
            .modified = try modified.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
            ._old_entries = old_entries,
            ._new_entries = new_entries,
            ._walk_entries = walk_entries,
        };
    }

    fn processFileForDiff(allocator: std.mem.Allocator, root: std.fs.Dir, we: walker_mod.WalkEntry, result: *tree_mod.TreeEntry) void {
        result.* = .{ .path = we.path, .mode = we.mode, .size = we.size, .mtime_ns = we.mtime_ns, .chunk_hashes = &.{} };

        const file = root.openFile(we.path, .{}) catch return;
        defer file.close();
        const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return;
        defer allocator.free(data);

        var count: usize = 0;
        {
            var cdc = chunker_mod.FastCDC.init(data, .{});
            while (cdc.next()) |_| count += 1;
        }
        const hashes = allocator.alloc(Hash, count) catch return;
        var idx: usize = 0;
        var cdc = chunker_mod.FastCDC.init(data, .{});
        while (cdc.next()) |chunk| {
            hashes[idx] = hash_mod.hashBytes(chunk.data);
            idx += 1;
        }
        result.chunk_hashes = hashes;
    }

    // ── List ──

    pub fn list(self: *Repo) ![]manifest_mod.Manifest {
        const head = try manifest_mod.readHead(self.cp_dir);
        if (head == null) return &.{};

        var manifests: std.ArrayList(manifest_mod.Manifest) = .{};
        errdefer manifests.deinit(self.allocator);

        var id: u32 = 1;
        while (id <= head.?) : (id += 1) {
            const m = manifest_mod.read(self.allocator, self.manifests_dir, id) catch continue;
            try manifests.append(self.allocator, m);
        }

        return manifests.toOwnedSlice(self.allocator);
    }

    // ── Internal ──

    fn loadPreviousTree(self: *Repo) ?[]tree_mod.TreeEntry {
        const head = manifest_mod.readHead(self.cp_dir) catch return null;
        const head_id = head orelse return null;
        const m = manifest_mod.read(self.allocator, self.manifests_dir, head_id) catch return null;
        defer if (m.name.len > 0) self.allocator.free(m.name);
        const tree_data = self.pack.readChunk(m.tree_hash) catch return null;
        defer self.allocator.free(tree_data);
        return tree_mod.deserialize(self.allocator, tree_data) catch null;
    }

    fn prune(self: *Repo, current_id: u32) !void {
        if (current_id <= MAX_SNAPSHOTS) return;
        const delete_up_to = current_id - MAX_SNAPSHOTS;
        self.deleteManifestsUpTo(delete_up_to);
    }

    pub fn pruneKeepLast(self: *Repo, keep: u32) !u32 {
        const head = try manifest_mod.readHead(self.cp_dir);
        const head_id = head orelse return 0;
        if (head_id <= keep) return 0;
        const delete_up_to = head_id - keep;
        self.deleteManifestsUpTo(delete_up_to);
        return delete_up_to;
    }

    fn deleteManifestsUpTo(self: *Repo, up_to: u32) void {
        var id: u32 = 1;
        while (id <= up_to) : (id += 1) {
            var name_buf: [32]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch continue;
            self.manifests_dir.deleteFile(filename) catch {};
        }
    }

    /// Read a file's content from a snapshot by reassembling its chunks
    pub fn readSnapshotFile(self: *Repo, snapshot_id: u32, path: []const u8) !?[]u8 {
        const m = try manifest_mod.read(self.allocator, self.manifests_dir, snapshot_id);
        defer if (m.name.len > 0) self.allocator.free(m.name);

        const tree_data = try self.pack.readChunk(m.tree_hash);
        defer self.allocator.free(tree_data);
        const entries = try tree_mod.deserialize(self.allocator, tree_data);
        defer tree_mod.freeEntries(self.allocator, entries);

        const entry = findEntry(entries, path) orelse return null;

        if (entry.chunk_hashes.len == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        var total_size: usize = 0;
        for (entry.chunk_hashes) |h| {
            const e = self.pack.getEntry(h) orelse return error.ChunkNotFound;
            total_size += e.raw_len;
        }

        const buf = try self.allocator.alloc(u8, total_size);
        var pos: usize = 0;
        for (entry.chunk_hashes) |h| {
            const chunk_data = try self.pack.readChunk(h);
            defer self.allocator.free(chunk_data);
            @memcpy(buf[pos..][0..chunk_data.len], chunk_data);
            pos += chunk_data.len;
        }
        return buf;
    }

    fn cleanEmptyDirs(self: *Repo) !void {
        var iter = try self.root.walk(self.allocator);
        defer iter.deinit();

        var dirs: std.ArrayList([]const u8) = .{};
        defer {
            for (dirs.items) |d| self.allocator.free(d);
            dirs.deinit(self.allocator);
        }

        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.startsWith(u8, entry.path, CHECKPOINT_DIR)) continue;
                if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;
                try dirs.append(self.allocator, try self.allocator.dupe(u8, entry.path));
            }
        }

        var i = dirs.items.len;
        while (i > 0) {
            i -= 1;
            self.root.deleteDir(dirs.items[i]) catch {};
        }
    }
};

pub const DiffResult = struct {
    added: [][]const u8,
    removed: [][]const u8,
    modified: [][]const u8,
    allocator: std.mem.Allocator,
    _old_entries: []tree_mod.TreeEntry,
    _new_entries: []tree_mod.TreeEntry,
    _walk_entries: []walker_mod.WalkEntry,

    pub fn deinit(self: *DiffResult) void {
        for (self.added) |p| self.allocator.free(p);
        self.allocator.free(self.added);
        for (self.removed) |p| self.allocator.free(p);
        self.allocator.free(self.removed);
        for (self.modified) |p| self.allocator.free(p);
        self.allocator.free(self.modified);

        tree_mod.freeEntries(self.allocator, self._old_entries);
        for (self._new_entries) |e| {
            if (e.chunk_hashes.len > 0) self.allocator.free(e.chunk_hashes);
        }
        self.allocator.free(self._new_entries);
        for (self._walk_entries) |e| self.allocator.free(e.path);
        self.allocator.free(self._walk_entries);
    }
};

fn findEntry(entries: []const tree_mod.TreeEntry, path: []const u8) ?tree_mod.TreeEntry {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, entries[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return entries[mid],
        }
    }
    return null;
}

fn hashListEqual(a: []const Hash, b: []const Hash) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true; // same slice = reused, definitely equal
    for (a, b) |ha, hb| {
        if (!std.mem.eql(u8, &ha, &hb)) return false;
    }
    return true;
}
