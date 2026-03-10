const std = @import("std");

pub const WalkEntry = struct {
    path: []const u8, // relative to root, owned
    size: u64,
    mtime_ns: i128,
    mode: u16,
};

pub const Walker = struct {
    allocator: std.mem.Allocator,
    ignore_patterns: std.ArrayList([]const u8),
    patterns_start: usize, // index where dynamically allocated patterns begin

    pub fn init(allocator: std.mem.Allocator, root: std.fs.Dir) !Walker {
        var w = Walker{
            .allocator = allocator,
            .ignore_patterns = .{},
            .patterns_start = 0,
        };

        // Always ignore these (static strings, not allocated)
        try w.ignore_patterns.append(allocator, ".checkpoint-files");
        try w.ignore_patterns.append(allocator, ".git");
        w.patterns_start = w.ignore_patterns.items.len;

        // Load .gitignore
        w.loadIgnoreFile(root, ".gitignore") catch {};

        return w;
    }

    pub fn deinit(self: *Walker) void {
        for (self.ignore_patterns.items[self.patterns_start..]) |p| {
            self.allocator.free(p);
        }
        self.ignore_patterns.deinit(self.allocator);
    }

    fn loadIgnoreFile(self: *Walker, dir: std.fs.Dir, name: []const u8) !void {
        const file = try dir.openFile(name, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '!') continue;

            const pattern = std.mem.trimRight(u8, trimmed, "/");
            if (pattern.len == 0) continue;

            const owned = try self.allocator.dupe(u8, pattern);
            try self.ignore_patterns.append(self.allocator, owned);
        }
    }

    pub fn walk(self: *Walker, root: std.fs.Dir) ![]WalkEntry {
        var entries: std.ArrayList(WalkEntry) = .{};
        errdefer {
            for (entries.items) |e| self.allocator.free(e.path);
            entries.deinit(self.allocator);
        }

        var iter = try root.walk(self.allocator);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (self.isIgnored(entry.path)) continue;

            const path = try self.allocator.dupe(u8, entry.path);
            const stat = root.statFile(entry.path) catch continue;

            try entries.append(self.allocator, .{
                .path = path,
                .size = stat.size,
                .mtime_ns = stat.mtime,
                .mode = 0o100644,
            });
        }

        std.mem.sort(WalkEntry, entries.items, {}, struct {
            fn f(_: void, a: WalkEntry, b: WalkEntry) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.f);

        return entries.toOwnedSlice(self.allocator);
    }

    fn isIgnored(self: *Walker, path: []const u8) bool {
        for (self.ignore_patterns.items) |pattern| {
            if (matchPattern(pattern, path)) return true;
        }
        return false;
    }
};

fn matchPattern(pattern: []const u8, path: []const u8) bool {
    // Check if any path component matches exactly
    var comp_iter = std.mem.splitScalar(u8, path, '/');
    while (comp_iter.next()) |component| {
        if (std.mem.eql(u8, component, pattern)) return true;
    }

    // Wildcard matching
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        if (suffix.len > 0 and suffix[0] == '*') {
            return std.mem.indexOf(u8, path, prefix) != null;
        }

        const basename = std.fs.path.basename(path);
        if (basename.len >= prefix.len + suffix.len) {
            if (std.mem.startsWith(u8, basename, prefix) and
                std.mem.endsWith(u8, basename, suffix))
            {
                return true;
            }
        }
    }

    return false;
}
