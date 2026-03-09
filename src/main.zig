const std = @import("std");
const repo_mod = @import("repo.zig");
const manifest_mod = @import("manifest.zig");

const VERSION = "0.0.1";

const USAGE =
    \\check                       save snapshot
    \\check --note "message"      save snapshot with a note
    \\check undo                  restore previous snapshot
    \\check restore [id]          restore to snapshot (default: latest)
    \\check diff [id]             show added/removed/modified files
    \\check diff [id] <path>      show content diff for one file
    \\check list [--recent N]     show all (or last N) snapshots
    \\check cleanup --keep N      delete all but last N snapshots
    \\
;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
    _ = std.posix.write(std.posix.STDERR_FILENO, "\n") catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const cmd = args.next();

    // No args → save (create repo if needed)
    if (cmd == null) {
        return doSave(allocator, null);
    }

    const command = cmd.?;

    if (std.mem.eql(u8, command, "--note")) {
        const note = args.next() orelse fatal("--note requires a value", .{});
        return doSave(allocator, note);
    }

    if (std.mem.eql(u8, command, "undo")) {
        return doUndo(allocator);
    }

    if (std.mem.eql(u8, command, "restore")) {
        const id = parseOptionalId(args.next());
        return doRestore(allocator, id);
    }

    if (std.mem.eql(u8, command, "diff")) {
        const next = args.next();
        const id = parseOptionalId(next);
        const path = if (id != null) args.next() else if (next != null and !isNumeric(next.?)) next else args.next();
        return doDiff(allocator, id, path);
    }

    if (std.mem.eql(u8, command, "list")) {
        const next = args.next();
        var recent: ?u32 = null;
        if (next) |n| {
            if (std.mem.eql(u8, n, "--recent")) {
                const val = args.next() orelse fatal("--recent requires a number", .{});
                recent = std.fmt.parseInt(u32, val, 10) catch fatal("--recent requires a number", .{});
            }
        }
        return doList(allocator, recent);
    }

    if (std.mem.eql(u8, command, "cleanup")) {
        const flag = args.next() orelse {
            fatal("check cleanup --keep N required (prevents deleting all snapshots)", .{});
        };
        if (!std.mem.eql(u8, flag, "--keep")) fatal("usage: check cleanup --keep N", .{});
        const val = args.next() orelse fatal("--keep requires a number", .{});
        const keep = std.fmt.parseInt(u32, val, 10) catch fatal("--keep requires a number", .{});
        if (keep == 0) fatal("--keep must be at least 1", .{});
        return doCleanup(allocator, keep);
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        out("check {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        out("{s}", .{USAGE});
        return;
    }

    out("{s}", .{USAGE});
}

fn openCwd() std.fs.Dir {
    return std.fs.cwd().openDir(".", .{ .iterate = true }) catch |e| {
        fatal("failed to open current directory: {}", .{e});
    };
}

fn doSave(allocator: std.mem.Allocator, name: ?[]const u8) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) {
            var r2 = repo_mod.Repo.create(allocator, cwd) catch |e| fatal("failed to create repo: {}", .{e});
            defer r2.deinit();
            const id = r2.save(name) catch |e| fatal("save failed: {}", .{e});
            if (name) |n| {
                out("saved #{d} \"{s}\"\n", .{ id, n });
            } else {
                out("saved #{d}\n", .{id});
            }
            return;
        }
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    const id = r.save(name) catch |e| fatal("save failed: {}", .{e});
    if (name) |n| {
        out("saved #{d} \"{s}\"\n", .{ id, n });
    } else {
        out("saved #{d}\n", .{id});
    }
}

fn doUndo(allocator: std.mem.Allocator) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    const head = manifest_mod.readHead(r.cp_dir) catch fatal("failed to read HEAD", .{});
    const head_id = head orelse fatal("no snapshots to undo", .{});
    if (head_id < 2) fatal("no previous snapshot to undo to", .{});
    const prev_id = head_id - 1;
    r.restore(prev_id) catch |e| fatal("undo failed: {}", .{e});
    out("undone to #{d}\n", .{prev_id});
}

fn doRestore(allocator: std.mem.Allocator, id: ?u32) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    r.restore(id) catch |e| fatal("restore failed: {}", .{e});
    if (id) |i| {
        out("restored #{d}\n", .{i});
    } else {
        out("restored to latest\n", .{});
    }
}

fn doDiff(allocator: std.mem.Allocator, id: ?u32, path: ?[]const u8) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Resolve which snapshot we're comparing against
    const resolved_id = if (id) |i| i else blk: {
        const head = manifest_mod.readHead(r.cp_dir) catch fatal("failed to read HEAD", .{});
        break :blk head orelse fatal("no snapshots", .{});
    };

    var result = r.diff(resolved_id) catch |e| fatal("diff failed: {}", .{e});
    defer result.deinit();

    if (path) |p| {
        // Read snapshot version
        const old_content = r.readSnapshotFile(resolved_id, p) catch |e| fatal("failed to read snapshot file: {}", .{e});
        defer if (old_content) |c| allocator.free(c);

        // Read current working tree version
        const current: ?[]u8 = blk: {
            const f = cwd.openFile(p, .{}) catch break :blk null;
            defer f.close();
            break :blk f.readToEndAlloc(allocator, 256 * 1024 * 1024) catch null;
        };
        defer if (current) |c| allocator.free(c);

        if (old_content == null and current == null) {
            out("{s}: not found in snapshot or working tree\n", .{p});
            return;
        }

        const old_text: []const u8 = old_content orelse "";
        const new_text: []const u8 = current orelse "";

        if (std.mem.eql(u8, old_text, new_text)) {
            out("{s}: no changes\n", .{p});
            return;
        }

        out("--- #{d} {s}\n", .{ resolved_id, p });
        out("+++ working tree {s}\n", .{p});
        printSimpleDiff(allocator, old_text, new_text);
        return;
    }

    // Header: which snapshot
    out("diff working tree vs #{d}\n", .{resolved_id});

    if (result.added.len == 0 and result.removed.len == 0 and result.modified.len == 0) {
        out("no changes\n", .{});
        return;
    }

    for (result.added) |p| out("  + {s}\n", .{p});
    for (result.removed) |p| out("  - {s}\n", .{p});
    for (result.modified) |p| out("  ~ {s}\n", .{p});
}

fn doList(allocator: std.mem.Allocator, recent: ?u32) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const manifests = r.list() catch |e| fatal("list failed: {}", .{e});
    defer {
        for (manifests) |m| {
            if (m.name.len > 0) allocator.free(m.name);
        }
        allocator.free(manifests);
    }

    if (manifests.len == 0) {
        out("no snapshots\n", .{});
        return;
    }

    // Print full path of checkpoint storage
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.posix.getcwd(&path_buf) catch "/";
    out("{s}/.checkpoint-files/\n", .{cwd_path});

    // Print newest first, limited by --recent
    const show_count = if (recent) |n| @min(n, manifests.len) else manifests.len;
    var i = manifests.len;
    var shown: usize = 0;
    while (i > 0 and shown < show_count) {
        i -= 1;
        shown += 1;
        const m = manifests[i];
        const name_display: []const u8 = if (m.name.len > 0) m.name else "-";
        const ts = formatTimestamp(m.timestamp);
        out("#{d:<4} {s:<20} {d:>4} files  {s} UTC\n", .{
            m.id,
            name_display,
            m.file_count,
            @as([]const u8, &ts),
        });
    }
}

fn doCleanup(allocator: std.mem.Allocator, keep: u32) void {
    var cwd = openCwd();
    defer cwd.close();
    var r = repo_mod.Repo.open(allocator, cwd) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    const deleted = r.pruneKeepLast(keep) catch |e| fatal("cleanup failed: {}", .{e});
    if (deleted == 0) {
        out("nothing to clean up\n", .{});
    } else {
        out("removed {d} snapshots, kept last {d}\n", .{ deleted, keep });
    }
}

fn formatTimestamp(unix: u64) [16]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = unix };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    const hour = ds.getHoursIntoDay();
    const minute = ds.getMinutesIntoHour();

    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        @as(u32, md.month.numeric()),
        @as(u32, md.day_index + 1),
        hour,
        minute,
    }) catch unreachable;
    return buf;
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) []const []const u8 {
    if (text.len == 0) return &.{};

    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;

    const lines = allocator.alloc([]const u8, count) catch return &.{};

    var idx: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, j| {
        if (c == '\n') {
            lines[idx] = text[start..j];
            idx += 1;
            start = j + 1;
        }
    }
    if (start < text.len) {
        lines[idx] = text[start..];
    }
    return lines;
}

fn printSimpleDiff(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) void {
    const old_lines = splitLines(allocator, old_text);
    defer allocator.free(old_lines);
    const new_lines = splitLines(allocator, new_text);
    defer allocator.free(new_lines);

    const old_len = old_lines.len;
    const new_len = new_lines.len;

    // If too large for O(n*m), fall back to simple output
    if (old_len * new_len > 1_000_000) {
        for (old_lines) |line| out("-{s}\n", .{line});
        for (new_lines) |line| out("+{s}\n", .{line});
        return;
    }

    const matrix = allocator.alloc(u32, (old_len + 1) * (new_len + 1)) catch {
        for (old_lines) |line| out("-{s}\n", .{line});
        for (new_lines) |line| out("+{s}\n", .{line});
        return;
    };
    defer allocator.free(matrix);

    // lcs[i][j] = LCS length of old[i..] and new[j..]
    for (0..old_len + 1) |ii| matrix[ii * (new_len + 1) + new_len] = 0;
    for (0..new_len + 1) |jj| matrix[old_len * (new_len + 1) + jj] = 0;

    var oi = old_len;
    while (oi > 0) {
        oi -= 1;
        var ni = new_len;
        while (ni > 0) {
            ni -= 1;
            if (std.mem.eql(u8, old_lines[oi], new_lines[ni])) {
                matrix[oi * (new_len + 1) + ni] = matrix[(oi + 1) * (new_len + 1) + (ni + 1)] + 1;
            } else {
                const a = matrix[(oi + 1) * (new_len + 1) + ni];
                const b = matrix[oi * (new_len + 1) + (ni + 1)];
                matrix[oi * (new_len + 1) + ni] = if (a > b) a else b;
            }
        }
    }

    // Traceback into ops array
    const CONTEXT = 3;
    const DiffOp = enum { keep, remove, add };
    const ops = allocator.alloc(DiffOp, old_len + new_len) catch return;
    defer allocator.free(ops);
    const op_lines = allocator.alloc([]const u8, old_len + new_len) catch return;
    defer allocator.free(op_lines);
    var op_count: usize = 0;

    var oi2: usize = 0;
    var ni2: usize = 0;
    while (oi2 < old_len or ni2 < new_len) {
        if (oi2 < old_len and ni2 < new_len and std.mem.eql(u8, old_lines[oi2], new_lines[ni2])) {
            ops[op_count] = .keep;
            op_lines[op_count] = old_lines[oi2];
            op_count += 1;
            oi2 += 1;
            ni2 += 1;
        } else if (oi2 < old_len and (ni2 >= new_len or matrix[(oi2 + 1) * (new_len + 1) + ni2] >= matrix[oi2 * (new_len + 1) + (ni2 + 1)])) {
            ops[op_count] = .remove;
            op_lines[op_count] = old_lines[oi2];
            op_count += 1;
            oi2 += 1;
        } else {
            ops[op_count] = .add;
            op_lines[op_count] = new_lines[ni2];
            op_count += 1;
            ni2 += 1;
        }
    }

    // Print with context lines (unified diff style)
    var idx: usize = 0;
    while (idx < op_count) {
        if (ops[idx] == .keep) { idx += 1; continue; }

        const hunk_start = if (idx >= CONTEXT) idx - CONTEXT else 0;
        var print_idx = hunk_start;

        var end = idx;
        while (end < op_count) {
            if (ops[end] != .keep) { end += 1; continue; }
            var keep_run: usize = 0;
            var scan = end;
            while (scan < op_count and ops[scan] == .keep) { keep_run += 1; scan += 1; }
            if (keep_run > CONTEXT * 2) { end += CONTEXT; break; }
            end = scan;
        }
        if (end > op_count) end = op_count;

        while (print_idx < end) {
            switch (ops[print_idx]) {
                .keep => out(" {s}\n", .{op_lines[print_idx]}),
                .remove => out("-{s}\n", .{op_lines[print_idx]}),
                .add => out("+{s}\n", .{op_lines[print_idx]}),
            }
            print_idx += 1;
        }
        idx = end;
    }
}

fn parseOptionalId(arg: ?[]const u8) ?u32 {
    const a = arg orelse return null;
    if (!isNumeric(a)) return null;
    return std.fmt.parseInt(u32, a, 10) catch null;
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}
