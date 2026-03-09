# Checkpoint — the `check` command you don't know you need

Fast, snapshot-based checkpoints for entire codebase. No branches, no staging, no merge conflicts.

## Install

Requires: Zig 0.15+, libzstd

```
make install    # installs to /usr/local/bin/check
make uninstall
```

## Usage

```
check                       save snapshot
check --note "message"      save with a note
check undo                  restore previous snapshot
check restore [id]          restore to snapshot
check diff [id]             show changed files
check diff [id] <path>      show content diff for a file
check list [--recent N]     list snapshots
check cleanup --keep N      delete all but last N snapshots
check version               show version
```

## Performance

Incremental save (~5% files changed):

| Files | check | git stash | Speedup |
|-------|-------|-----------|---------|
| 50    | 6ms   | 91ms      | 15x     |
| 500   | 5ms   | 66ms      | 13x     |
| 2000  | 4ms   | 190ms     | 47x     |

`make bench` to reproduce.

## How it works

FastCDC content-defined chunking, BLAKE3 hashing, zstd compression. Unchanged files skipped via mtime+size. File processing parallelized across cores; pack writes are sequential (single append-only file).
