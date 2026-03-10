# Checkpoint — the `check` command you don't know you need

Fast, snapshot-based checkpoints for entire codebase. No branches, no staging, no merge conflicts.

## Install

```
brew install kaxing/checkpoint/check
// uninstall: brew uninstall check
```

### From source

```
git clone https://github.com/kaxing/checkpoint
cd checkpoint
make install    # installs to /usr/local/bin/check
// uninstall: make uninstall
```

Requires: Zig 0.15+

## Usage

```
check                       create checkpoint
check --note "message"      create checkpoint with a note
check rollback [id]         rollback to checkpoint (default: latest)
check diff [id]             show added/removed/modified files
check diff [id] <path>      show content diff for one file
check list [--recent N]     show all (or last N) checkpoints
check remove <id>           remove a checkpoint
check remove --keep N       delete all but last N
check remove all            remove all checkpoints
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
