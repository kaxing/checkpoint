# Changelog

## v0.0.3

Breaking changes:

- `.checkpoint-files/HEAD` renamed to `.checkpoint-files/latest`

New:

- `check note <id> "message"` adds or updates a note on a checkpoint
- `check` skips save if current state matches an existing checkpoint
- Disk space check: refuses to save when disk is >93.75% full (free < 1/16)

## v0.0.2

Breaking changes:

- `check restore` renamed to `check rollback`
- `check undo` removed (use `check rollback`)
- `check cleanup --keep N` moved to `check remove --keep N`
- `check version` output changed from `check 0.0.1` to `v0.0.2`
- All user-facing text: "snapshot" renamed to "checkpoint"

New:

- `check rollback` auto-saves current state as `<auto>` before restoring
- Smart auto: skips `<auto>` if current state matches an existing checkpoint
- `check remove <id>` removes a specific checkpoint
- `check remove --keep N` deletes all but last N
- `check remove all` removes all checkpoints (asks confirmation)

## v0.0.1

Initial release.
