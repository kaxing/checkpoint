#!/usr/bin/env bash
#
# Integration tests for check CLI
# Usage: bash test-coverage/integration.sh [path-to-check-binary]
#

set -euo pipefail

CHECK="$(cd "$(dirname "${1:-./zig-out/bin/check}")" && pwd)/$(basename "${1:-./zig-out/bin/check}")"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR_BASE"; }
trap cleanup EXIT

# --- helpers ---

new_test_dir() {
    local d="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$d"
    echo "$d"
}

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"; }

assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}

assert_contains() {
    if echo "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3" "output missing '$2'"; fi
}

assert_exit_fail() {
    if eval "$1" >/dev/null 2>&1; then fail "$2" "expected non-zero exit"; else pass "$2"; fi
}

assert_file_eq() {
    if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "files differ: $1 vs $2"; fi
}

# ============================================================
echo "=== Basic save & rollback ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "hello" > file.txt
mkdir -p sub
echo "nested" > sub/deep.txt

OUT=$($CHECK 2>&1)
assert_contains "$OUT" "checkpoint #1" "create first checkpoint"

# modify files
echo "changed" > file.txt
echo "new" > added.txt
rm sub/deep.txt

$CHECK rollback 1 2>&1 >/dev/null
assert_eq "$(cat file.txt)" "hello" "rollback file content"
assert_eq "$(cat sub/deep.txt)" "nested" "rollback nested file"
[ ! -f added.txt ] && pass "rollback removes added file" || fail "rollback removes added file" "added.txt still exists"

# ============================================================
echo "=== Save with --note ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "a" > f.txt

OUT=$($CHECK --note "my note" 2>&1)
assert_contains "$OUT" '"my note"' "save with note"

OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "my note" "list shows note"

# ============================================================
echo "=== Version ==="
# ============================================================

OUT=$($CHECK version 2>&1)
assert_contains "$OUT" "v0." "version output"

OUT=$($CHECK --version 2>&1)
assert_contains "$OUT" "v0." "--version flag"

# ============================================================
echo "=== Help ==="
# ============================================================

OUT=$($CHECK --help 2>&1)
assert_contains "$OUT" "check" "help output"
assert_contains "$OUT" "--note" "help mentions --note"
assert_contains "$OUT" "rollback" "help mentions rollback"
assert_contains "$OUT" "remove" "help mentions remove"

# ============================================================
echo "=== Diff (file list) ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "original" > keep.txt
echo "old" > modify.txt
echo "remove_me" > remove.txt
$CHECK >/dev/null 2>&1

echo "modified" > modify.txt
echo "brand_new" > added.txt
rm remove.txt

OUT=$($CHECK diff 2>&1)
assert_contains "$OUT" "diff current vs #1" "diff header"
assert_contains "$OUT" "+ added.txt" "diff shows added"
assert_contains "$OUT" "- remove.txt" "diff shows removed"
assert_contains "$OUT" "~ modify.txt" "diff shows modified"

# ============================================================
echo "=== Diff (file content) ==="
# ============================================================

OUT=$($CHECK diff 1 modify.txt 2>&1)
assert_contains "$OUT" "--- #1 modify.txt" "content diff header old"
assert_contains "$OUT" "+++ current modify.txt" "content diff header new"
assert_contains "$OUT" "-old" "content diff shows removed line"
assert_contains "$OUT" "+modified" "content diff shows added line"

# diff unchanged file
echo "original" > keep.txt
OUT=$($CHECK diff 1 keep.txt 2>&1)
assert_contains "$OUT" "no changes" "diff unchanged file"

# diff new file (not in snapshot)
OUT=$($CHECK diff 1 added.txt 2>&1)
assert_contains "$OUT" "+brand_new" "diff new file shows added"

# ============================================================
echo "=== Rollback auto-saves <auto> ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1
echo "v3-unsaved" > f.txt

# Rollback to #1 should auto-save current state
OUT=$($CHECK rollback 1 2>&1)
assert_contains "$OUT" "<auto>" "rollback auto-saves <auto>"
assert_contains "$OUT" "rolled back to #1" "rollback message"
assert_eq "$(cat f.txt)" "v1" "rollback restores content"

# The <auto> checkpoint should be in the list
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "<auto>" "list shows <auto> checkpoint"

# Can rollback to <auto> to get unsaved state back
AUTO_ID=$(echo "$OUT" | grep '<auto>' | head -1 | sed 's/#\([0-9]*\).*/\1/')
$CHECK rollback "$AUTO_ID" 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v3-unsaved" "rollback to <auto> restores unsaved state"

# ============================================================
echo "=== Rollback smart auto (skip duplicate) ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1

# Rollback to #1 — current state matches snap2, so <auto> should be skipped
OUT=$($CHECK rollback 1 2>&1)
assert_eq "$(cat f.txt)" "v1" "smart auto rollback restores content"
# <auto> should NOT appear since current state == snap2
OUT=$($CHECK list 2>&1)
if echo "$OUT" | grep -qF "<auto>"; then
    fail "smart auto skips duplicate" "<auto> should not appear"
else
    pass "smart auto skips duplicate"
fi

# ============================================================
echo "=== Rollback only one <auto> ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1
echo "v3-dirty" > f.txt

# First rollback creates <auto>
$CHECK rollback 1 2>&1 >/dev/null
echo "v4-dirty" > f.txt
# Second rollback should replace old <auto>, not create a second one
$CHECK rollback 2 2>&1 >/dev/null

OUT=$($CHECK list 2>&1)
AUTO_COUNT=$(echo "$OUT" | grep -cF "<auto>" || true)
assert_eq "$AUTO_COUNT" "1" "only one <auto> exists after multiple rollbacks"

# ============================================================
echo "=== Rollback defaults to latest ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1
echo "v3-dirty" > f.txt

OUT=$($CHECK rollback 2>&1)
assert_contains "$OUT" "rolled back to latest" "rollback defaults to latest"
assert_eq "$(cat f.txt)" "v2" "rollback latest restores snap2 content"

# ============================================================
echo "=== Remove ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1
echo "v3" > f.txt
$CHECK --note "snap3" >/dev/null 2>&1

OUT=$($CHECK remove 2 2>&1)
assert_contains "$OUT" "removed #2" "remove message"

# verify #2 is gone from list
OUT=$($CHECK list 2>&1)
if echo "$OUT" | grep -qF "snap2"; then
    fail "remove deletes checkpoint" "snap2 still listed"
else
    pass "remove deletes checkpoint"
fi
assert_contains "$OUT" "snap1" "remove keeps other checkpoints (snap1)"
assert_contains "$OUT" "snap3" "remove keeps other checkpoints (snap3)"

# remove requires id
# remove without args shows usage (exit 0)
OUT=$($CHECK remove 2>&1)
assert_contains "$OUT" "check remove" "remove without args shows usage in remove section"

# remove nonexistent
assert_exit_fail "cd $DIR && $CHECK remove 99" "remove nonexistent checkpoint fails"

# ============================================================
echo "=== List --recent ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
for i in 1 2 3 4 5; do
    echo "v$i" > f.txt
    $CHECK --note "snap$i" >/dev/null 2>&1
done

OUT=$($CHECK list --recent 2 2>&1)
assert_contains "$OUT" "snap5" "list --recent shows newest"
assert_contains "$OUT" "snap4" "list --recent shows second"
# snap3 should NOT appear
if echo "$OUT" | grep -qF "snap3"; then
    fail "list --recent limits output" "snap3 should not appear"
else
    pass "list --recent limits output"
fi

# full list shows all
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "snap1" "full list shows oldest"
assert_contains "$OUT" "snap5" "full list shows newest"

# ============================================================
echo "=== Remove --keep ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
for i in 1 2 3 4 5; do
    echo "v$i" > f.txt
    $CHECK --note "snap$i" >/dev/null 2>&1
done

OUT=$($CHECK remove --keep 2 2>&1)
assert_contains "$OUT" "removed 3" "remove --keep removes correct count"
assert_contains "$OUT" "kept last 2" "remove --keep reports kept count"

# verify only last 2 remain in list
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "snap5" "remove --keep keeps snap5"
assert_contains "$OUT" "snap4" "remove --keep keeps snap4"
if echo "$OUT" | grep -qF "snap3"; then
    fail "remove --keep removes old checkpoints" "snap3 still listed"
else
    pass "remove --keep removes old checkpoints"
fi

# ============================================================
echo "=== Remove --keep safety ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "x" > f.txt
$CHECK >/dev/null 2>&1

assert_exit_fail "cd $DIR && $CHECK remove --keep 0" "remove --keep 0 fails"

# nothing to clean
OUT=$($CHECK remove --keep 10 2>&1)
assert_contains "$OUT" "nothing to clean" "remove --keep when nothing to do"

# ============================================================
echo "=== Remove usage ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "x" > f.txt
$CHECK >/dev/null 2>&1

OUT=$($CHECK remove 2>&1)
assert_contains "$OUT" "check remove" "remove without args shows usage"

# ============================================================
echo "=== Remove all ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
for i in 1 2 3; do
    echo "v$i" > f.txt
    $CHECK --note "snap$i" >/dev/null 2>&1
done

# remove all with "y" confirmation
OUT=$(echo "y" | $CHECK remove all 2>&1)
assert_contains "$OUT" "removed all 3" "remove all confirms and removes"

# list should show no checkpoints
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "no checkpoints" "no checkpoints after remove all"

# remove all with "n" should abort
DIR=$(new_test_dir)
cd "$DIR"
echo "x" > f.txt
$CHECK >/dev/null 2>&1
OUT=$(echo "n" | $CHECK remove all 2>&1)
assert_contains "$OUT" "aborted" "remove all aborts on n"
# checkpoint should still exist
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "#1" "checkpoint survives abort"

# ============================================================
echo "=== Empty file ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
touch empty.txt
$CHECK >/dev/null 2>&1
echo "now has content" > empty.txt
$CHECK rollback 1 2>&1 >/dev/null
assert_eq "$(cat empty.txt)" "" "rollback empty file"

# ============================================================
echo "=== Binary file roundtrip ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
dd if=/dev/urandom of=binary.bin bs=1024 count=100 2>/dev/null
cp binary.bin binary_orig.bin
$CHECK >/dev/null 2>&1

dd if=/dev/urandom of=binary.bin bs=1024 count=50 2>/dev/null
$CHECK rollback 1 2>&1 >/dev/null
assert_file_eq binary.bin binary_orig.bin "binary file roundtrip"

# ============================================================
echo "=== Nested directories ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
mkdir -p a/b/c/d
echo "deep" > a/b/c/d/file.txt
echo "mid" > a/b/mid.txt
$CHECK >/dev/null 2>&1

rm -rf a
$CHECK rollback 1 2>&1 >/dev/null
assert_eq "$(cat a/b/c/d/file.txt)" "deep" "rollback deep nested file"
assert_eq "$(cat a/b/mid.txt)" "mid" "rollback mid nested file"

# ============================================================
echo "=== Multiple checkpoints rollback ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK >/dev/null 2>&1
echo "v2" > f.txt
$CHECK >/dev/null 2>&1
echo "v3" > f.txt
$CHECK >/dev/null 2>&1

$CHECK rollback 1 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v1" "rollback to snap 1"
$CHECK rollback 2 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v2" "rollback to snap 2"
$CHECK rollback 3 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v3" "rollback to snap 3"

# ============================================================
echo "=== No checkpoints error ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
assert_exit_fail "cd $DIR && $CHECK rollback" "rollback with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK diff" "diff with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK list" "list with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK remove 1" "remove with no checkpoints"

# ============================================================
echo "=== List shows checkpoint path ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "x" > f.txt
$CHECK >/dev/null 2>&1

OUT=$($CHECK list 2>&1)
assert_contains "$OUT" ".checkpoint-files/" "list shows checkpoint path"

# ============================================================
# Summary
# ============================================================

echo ""
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    printf "\033[32mAll %d tests passed\033[0m\n" "$TOTAL"
else
    printf "\033[31m%d/%d tests failed\033[0m\n" "$FAIL" "$TOTAL"
    exit 1
fi
