const std = @import("std");
const repo_mod = @import("repo.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;
const Dir = Io.Dir;

const VERSION = "0.0.4";

const USAGE =
    \\checkpoint — local file snapshot tool
    \\
    \\  <id>    checkpoint number (shown as #1, #2, ... in list output)
    \\  <path>  file path relative to repo root (e.g. src/main.zig)
    \\
    \\check                       create checkpoint
    \\check "text"                create checkpoint with a note
    \\check rollback              rollback to latest checkpoint
    \\check rollback <id>         rollback to a specific checkpoint
    \\check rollback <id> <path>  rollback a single file
    \\check diff <id>             show added/removed/modified files
    \\check diff <id> <path>      show content diff for one file
    \\check list                  show all checkpoints
    \\check list <N>              show last N checkpoints
    \\check edit <id> "text"      update note
    \\check remove <id>           remove a checkpoint
    \\check remove --keep <N>     delete all but last N
    \\check remove all            remove all checkpoints
    \\check version               show version
    \\
;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.c.write(1, slice.ptr, slice.len);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
    std.process.exit(1);
}

var g_io: Io = undefined;

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(.{ .vector = init.minimal.args.vector });
    _ = args.next(); // skip program name

    const cmd = args.next();

    // No args → save (create repo if needed)
    if (cmd == null) {
        return doSave(allocator, null);
    }

    const command = cmd.?;

    if (std.mem.eql(u8, command, "rollback")) {
        const id = parseOptionalId(args.next());
        const path = args.next();
        if (path != null and id == null) fatal("usage: check rollback <id> <path>", .{});
        return doRollback(allocator, id, path);
    }

    if (std.mem.eql(u8, command, "edit")) {
        const id_str = args.next() orelse fatal("usage: check edit <id> \"text\"", .{});
        const id = std.fmt.parseInt(u32, id_str, 10) catch fatal("usage: check edit <id> \"text\"", .{});
        const note = args.next() orelse fatal("usage: check edit <id> \"text\"", .{});
        return doNote(allocator, id, note);
    }

    if (std.mem.eql(u8, command, "remove")) {
        const next = args.next() orelse {
            out("check remove <id>         remove a checkpoint\n", .{});
            out("check remove --keep N     delete all but last N\n", .{});
            out("check remove all          remove all checkpoints\n", .{});
            return;
        };
        if (std.mem.eql(u8, next, "all")) {
            return doRemoveAll(allocator);
        }
        if (std.mem.eql(u8, next, "--keep")) {
            const val = args.next() orelse fatal("--keep requires a number", .{});
            const keep = std.fmt.parseInt(u32, val, 10) catch fatal("--keep requires a number", .{});
            if (keep == 0) fatal("--keep must be at least 1", .{});
            return doCleanup(allocator, keep);
        }
        const id = std.fmt.parseInt(u32, next, 10) catch fatal("check remove <id> — id must be a number", .{});
        return doRemove(allocator, id);
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
            recent = std.fmt.parseInt(u32, n, 10) catch fatal("usage: check list <N>", .{});
        }
        return doList(allocator, recent);
    }


    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        out("v{s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        out("{s}", .{USAGE});
        return;
    }

    // Not a known subcommand — treat as note for save
    return doSave(allocator, command);
}

fn io() Io {
    return g_io;
}

const native = @import("builtin").target.os.tag;
const fsblkcnt_t = if (native == .macos) u32 else c_ulong;
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: fsblkcnt_t,
    f_bfree: fsblkcnt_t,
    f_bavail: fsblkcnt_t,
    f_files: fsblkcnt_t,
    f_ffree: fsblkcnt_t,
    f_favail: fsblkcnt_t,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
};
extern fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

fn checkDiskSpace() void {
    var buf: Statvfs = undefined;
    if (statvfs(".", &buf) != 0) return;
    if (buf.f_blocks > 0 and buf.f_bavail < buf.f_blocks >> 4) {
        fatal("disk almost full, skipping checkpoint", .{});
    }
}

fn isDuplicateCheckpoint(allocator: std.mem.Allocator, r: *repo_mod.Repo, id: u32) bool {
    const m = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch return false;
    defer if (m.name.len > 0) allocator.free(m.name);
    const manifests = r.list() catch return false;
    defer {
        for (manifests) |em| if (em.name.len > 0) allocator.free(em.name);
        allocator.free(manifests);
    }
    for (manifests) |em| {
        if (em.id == id) continue;
        if (std.mem.eql(u8, &em.tree_hash, &m.tree_hash)) return true;
    }
    return false;
}

fn removeDuplicateCheckpoint(r: *repo_mod.Repo, id: u32) void {
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;
    r.manifests_dir.deleteFile(io(), filename) catch {};
    if (id > 1) manifest_mod.writeHead(r.cp_dir, io(), id - 1) catch {};
}

fn openCwd() Dir {
    return Dir.cwd().openDir(io(), ".", .{ .iterate = true }) catch
        fatal("failed to open current directory", .{});
}

fn doSave(allocator: std.mem.Allocator, name: ?[]const u8) void {
    checkDiskSpace();
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.openOrCreate(allocator, cwd, io()) catch |e| fatal("failed to open repo: {}", .{e});
    defer r.deinit();
    const id = r.save(name) catch |e| fatal("save failed: {} (errno={})", .{ e, std.c._errno().* });
    if (isDuplicateCheckpoint(allocator, &r, id)) {
        removeDuplicateCheckpoint(&r, id);
        out("checkpoint already existed\n", .{});
        return;
    }
    if (name) |n| {
        out("checkpoint #{d} \"{s}\"\n", .{ id, n });
    } else {
        out("checkpoint #{d}\n", .{id});
    }
}

fn doRollback(allocator: std.mem.Allocator, id: ?u32, path: ?[]const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Resolve target before auto-saving
    const target_id = id orelse blk: {
        const head = manifest_mod.readHead(r.cp_dir, io()) catch fatal("failed to read latest", .{});
        break :blk head orelse fatal("no checkpoints found", .{});
    };

    // Single-file rollback: no auto-save, just restore the one file
    if (path) |file_path| {
        r.restoreFile(target_id, file_path) catch |e| {
            if (e == error.FileNotFound) fatal("file not in checkpoint #{d}: {s}", .{ target_id, file_path });
            fatal("rollback failed: {}", .{e});
        };
        out("rolled back {s} from #{d}\n", .{ file_path, target_id });
        return;
    }

    // Remove any existing <auto> checkpoint (unless it's our target)
    removeAutoCheckpoint(allocator, &r, target_id);

    // Auto-save current state
    const auto_id = r.save("<auto>") catch |e| fatal("failed to save current state: {}", .{e});

    if (isDuplicateCheckpoint(allocator, &r, auto_id)) {
        removeDuplicateCheckpoint(&r, auto_id);
    } else {
        out("checkpoint #{d} \"<auto>\"\n", .{auto_id});
    }

    r.restore(target_id) catch |e| fatal("rollback failed: {}", .{e});
    if (id) |_| {
        out("rolled back to #{d}\n", .{target_id});
    } else {
        out("rolled back to latest\n", .{});
    }
}

fn removeAutoCheckpoint(allocator: std.mem.Allocator, r: *repo_mod.Repo, skip_id: u32) void {
    const manifests = r.list() catch return;
    defer {
        for (manifests) |m| if (m.name.len > 0) allocator.free(m.name);
        allocator.free(manifests);
    }
    for (manifests) |m| {
        if (m.id == skip_id) continue;
        if (std.mem.eql(u8, m.name, "<auto>")) {
            var name_buf: [32]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch continue;
            r.manifests_dir.deleteFile(io(), filename) catch {};
            // Update latest if this was the top
            const head = manifest_mod.readHead(r.cp_dir, io()) catch continue;
            if (head) |h| {
                if (h == m.id and m.id > 1)
                    manifest_mod.writeHead(r.cp_dir, io(), m.id - 1) catch {};
            }
        }
    }
}

fn doNote(allocator: std.mem.Allocator, id: u32, note: []const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const m = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch |err| {
        if (err == error.FileNotFound) fatal("checkpoint #{d} not found", .{id});
        fatal("failed to read checkpoint #{d}: {}", .{ id, err });
    };
    defer if (m.name.len > 0) allocator.free(m.name);

    manifest_mod.write(r.manifests_dir, io(), .{
        .id = m.id,
        .timestamp = m.timestamp,
        .file_count = m.file_count,
        .total_size = m.total_size,
        .name = note,
        .tree_hash = m.tree_hash,
    }) catch |e| fatal("failed to update note: {}", .{e});

    out("#{d} \"{s}\"\n", .{ id, note });
}

fn doRemove(allocator: std.mem.Allocator, id: u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Check manifest exists
    _ = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch |err| {
        if (err == error.FileNotFound) fatal("checkpoint #{d} not found", .{id});
        fatal("failed to read checkpoint #{d}: {}", .{ id, err });
    };

    // Delete the manifest file
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;
    r.manifests_dir.deleteFile(io(), filename) catch |e| fatal("failed to remove checkpoint #{d}: {}", .{ id, e });

    // If this was latest, update to previous existing manifest
    const head = manifest_mod.readHead(r.cp_dir, io()) catch null;
    if (head) |h| {
        if (h == id) {
            var prev = id;
            while (prev > 1) {
                prev -= 1;
                var check_buf: [32]u8 = undefined;
                const check_name = std.fmt.bufPrint(&check_buf, "{d}.manifest", .{prev}) catch continue;
                if (r.manifests_dir.statFile(io(), check_name, .{})) |_| {
                    manifest_mod.writeHead(r.cp_dir, io(), prev) catch {};
                    break;
                } else |_| continue;
            }
        }
    }

    out("removed #{d}\n", .{id});
}

fn doDiff(allocator: std.mem.Allocator, id: ?u32, path: ?[]const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Resolve which snapshot we're comparing against
    const resolved_id = if (id) |i| i else blk: {
        const head = manifest_mod.readHead(r.cp_dir, io()) catch fatal("failed to read latest", .{});
        break :blk head orelse fatal("no checkpoints", .{});
    };

    var result = r.diff(resolved_id) catch |e| fatal("diff failed: {}", .{e});
    defer result.deinit();

    if (path) |p| {
        // Read snapshot version
        const old_content = r.readSnapshotFile(resolved_id, p) catch |e| fatal("failed to read snapshot file: {}", .{e});
        defer if (old_content) |c| allocator.free(c);

        // Read current working tree version
        const current: ?[]u8 = blk: {
            break :blk cwd.readFileAlloc(io(), p, allocator, .limited(256 * 1024 * 1024)) catch null;
        };
        defer if (current) |c| allocator.free(c);

        if (old_content == null and current == null) {
            out("{s}: not found in snapshot or current\n", .{p});
            return;
        }

        const old_text: []const u8 = old_content orelse "";
        const new_text: []const u8 = current orelse "";

        if (std.mem.eql(u8, old_text, new_text)) {
            out("{s}: no changes\n", .{p});
            return;
        }

        out("--- #{d} {s}\n", .{ resolved_id, p });
        out("+++ current {s}\n", .{p});
        printSimpleDiff(allocator, old_text, new_text);
        return;
    }

    // Header: which snapshot
    out("diff current vs #{d}\n", .{resolved_id});

    if (result.added.len == 0 and result.removed.len == 0 and result.modified.len == 0) {
        out("no changes\n", .{});
        return;
    }

    for (result.added) |p| out("  + {s}\n", .{p});
    for (result.removed) |p| out("  - {s}\n", .{p});
    for (result.modified) |p| out("  ~ {s}\n", .{p});
}

fn doList(allocator: std.mem.Allocator, recent: ?u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
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
        out("no checkpoints\n", .{});
        return;
    }

    // Print full path of checkpoint storage
    var path_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&path_buf, path_buf.len);
    if (cwd_ptr) |p| {
        const cwd_path = std.mem.sliceTo(p, 0);
        out("{s}/.checkpoint-files/\n", .{cwd_path});
    }

    // Print newest first, limited by recent
    const show_count = if (recent) |n| @min(n, manifests.len) else manifests.len;
    var i = manifests.len;
    var shown: usize = 0;
    while (i > 0 and shown < show_count) {
        i -= 1;
        shown += 1;
        const m = manifests[i];
        const name_display: []const u8 = if (m.name.len > 0) m.name else "-";
        const ts = formatTimestamp(m.timestamp);
        const size = formatSize(m.total_size);
        out("#{d:<4} {s:<20} {d:>4} files  {s}  {s} UTC\n", .{
            m.id,
            name_display,
            m.file_count,
            @as([]const u8, &size),
            @as([]const u8, &ts),
        });
    }
}

fn doCleanup(allocator: std.mem.Allocator, keep: u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    const deleted = r.pruneKeepLast(keep) catch |e| fatal("cleanup failed: {}", .{e});
    if (deleted == 0) {
        out("nothing to clean up\n", .{});
    } else {
        out("removed {d} checkpoints, kept last {d}\n", .{ deleted, keep });
    }
}

fn doRemoveAll(allocator: std.mem.Allocator) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no checkpoints found", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const manifests = r.list() catch |e| fatal("list failed: {}", .{e});
    defer {
        for (manifests) |m| if (m.name.len > 0) allocator.free(m.name);
        allocator.free(manifests);
    }

    if (manifests.len == 0) {
        out("no checkpoints to remove\n", .{});
        return;
    }

    out("remove all {d} checkpoints? [y/N] ", .{manifests.len});

    var buf: [16]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) fatal("aborted", .{});
    const answer = std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n\r \t");
    if (!std.mem.eql(u8, answer, "y") and !std.mem.eql(u8, answer, "Y")) {
        out("aborted\n", .{});
        return;
    }

    for (manifests) |m| {
        var name_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch continue;
        r.manifests_dir.deleteFile(io(), filename) catch {};
    }

    // Remove pack and latest
    r.cp_dir.deleteFile(io(), "latest") catch {};
    r.cp_dir.deleteFile(io(), "pack.dat") catch {};
    r.cp_dir.deleteFile(io(), "pack.idx") catch {};

    out("removed all {d} checkpoints\n", .{manifests.len});
}

fn formatSize(bytes: u64) [8]u8 {
    var buf: [8]u8 = .{' '} ** 8;
    if (bytes == 0) {
        _ = std.fmt.bufPrint(&buf, "   0B   ", .{}) catch {};
    } else if (bytes < 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}B   ", .{bytes}) catch {};
    } else if (bytes < 1024 * 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}KB  ", .{bytes / 1024}) catch {};
    } else if (bytes < 1024 * 1024 * 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}MB  ", .{bytes / (1024 * 1024)}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:>4}GB  ", .{bytes / (1024 * 1024 * 1024)}) catch {};
    }
    return buf;
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
