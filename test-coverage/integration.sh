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
echo "=== Basic save & restore ==="
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

$CHECK restore 1 2>&1 >/dev/null
assert_eq "$(cat file.txt)" "hello" "restore file content"
assert_eq "$(cat sub/deep.txt)" "nested" "restore nested file"
[ ! -f added.txt ] && pass "restore removes added file" || fail "restore removes added file" "added.txt still exists"

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
assert_contains "$OUT" "check " "version output"

OUT=$($CHECK --version 2>&1)
assert_contains "$OUT" "check " "--version flag"

# ============================================================
echo "=== Help ==="
# ============================================================

OUT=$($CHECK --help 2>&1)
assert_contains "$OUT" "check" "help output"
assert_contains "$OUT" "--note" "help mentions --note"
assert_contains "$OUT" "undo" "help mentions undo"
assert_contains "$OUT" "cleanup" "help mentions cleanup"

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
assert_contains "$OUT" "diff working tree vs #1" "diff header"
assert_contains "$OUT" "+ added.txt" "diff shows added"
assert_contains "$OUT" "- remove.txt" "diff shows removed"
assert_contains "$OUT" "~ modify.txt" "diff shows modified"

# ============================================================
echo "=== Diff (file content) ==="
# ============================================================

OUT=$($CHECK diff 1 modify.txt 2>&1)
assert_contains "$OUT" "--- #1 modify.txt" "content diff header old"
assert_contains "$OUT" "+++ working tree modify.txt" "content diff header new"
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
echo "=== Undo ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK --note "snap1" >/dev/null 2>&1
echo "v2" > f.txt
$CHECK --note "snap2" >/dev/null 2>&1
echo "v3" > f.txt
$CHECK --note "snap3" >/dev/null 2>&1

OUT=$($CHECK undo 2>&1)
assert_contains "$OUT" "undone to #2" "undo message"
assert_eq "$(cat f.txt)" "v2" "undo restores previous content"

# ============================================================
echo "=== Undo with single checkpoint ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "only" > f.txt
$CHECK >/dev/null 2>&1

assert_exit_fail "cd $DIR && $CHECK undo" "undo with single checkpoint fails"

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
echo "=== Cleanup --keep ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
for i in 1 2 3 4 5; do
    echo "v$i" > f.txt
    $CHECK --note "snap$i" >/dev/null 2>&1
done

OUT=$($CHECK cleanup --keep 2 2>&1)
assert_contains "$OUT" "removed 3" "cleanup removes correct count"
assert_contains "$OUT" "kept last 2" "cleanup reports kept count"

# verify only last 2 remain in list
OUT=$($CHECK list 2>&1)
assert_contains "$OUT" "snap5" "cleanup keeps snap5"
assert_contains "$OUT" "snap4" "cleanup keeps snap4"
if echo "$OUT" | grep -qF "snap3"; then
    fail "cleanup removes old checkpoints" "snap3 still listed"
else
    pass "cleanup removes old checkpoints"
fi

# ============================================================
echo "=== Cleanup safety ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "x" > f.txt
$CHECK >/dev/null 2>&1

assert_exit_fail "cd $DIR && $CHECK cleanup" "cleanup without --keep fails"
assert_exit_fail "cd $DIR && $CHECK cleanup --keep 0" "cleanup --keep 0 fails"

# nothing to clean
OUT=$($CHECK cleanup --keep 10 2>&1)
assert_contains "$OUT" "nothing to clean" "cleanup when nothing to do"

# ============================================================
echo "=== Empty file ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
touch empty.txt
$CHECK >/dev/null 2>&1
echo "now has content" > empty.txt
$CHECK restore 1 2>&1 >/dev/null
assert_eq "$(cat empty.txt)" "" "restore empty file"

# ============================================================
echo "=== Binary file roundtrip ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
dd if=/dev/urandom of=binary.bin bs=1024 count=100 2>/dev/null
cp binary.bin binary_orig.bin
$CHECK >/dev/null 2>&1

dd if=/dev/urandom of=binary.bin bs=1024 count=50 2>/dev/null
$CHECK restore 1 2>&1 >/dev/null
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
$CHECK restore 1 2>&1 >/dev/null
assert_eq "$(cat a/b/c/d/file.txt)" "deep" "restore deep nested file"
assert_eq "$(cat a/b/mid.txt)" "mid" "restore mid nested file"

# ============================================================
echo "=== Multiple checkpoints restore ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "v1" > f.txt
$CHECK >/dev/null 2>&1
echo "v2" > f.txt
$CHECK >/dev/null 2>&1
echo "v3" > f.txt
$CHECK >/dev/null 2>&1

$CHECK restore 1 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v1" "restore to snap 1"
$CHECK restore 2 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v2" "restore to snap 2"
$CHECK restore 3 2>&1 >/dev/null
assert_eq "$(cat f.txt)" "v3" "restore to snap 3"

# ============================================================
echo "=== No checkpoints error ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
assert_exit_fail "cd $DIR && $CHECK restore" "restore with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK diff" "diff with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK list" "list with no checkpoints"
assert_exit_fail "cd $DIR && $CHECK undo" "undo with no checkpoints"

# ============================================================
echo "=== .checkignore ==="
# ============================================================

DIR=$(new_test_dir)
cd "$DIR"
echo "*.log" > .checkignore
echo "important" > keep.txt
echo "debug output" > debug.log
$CHECK >/dev/null 2>&1

rm keep.txt debug.log
$CHECK restore 1 2>&1 >/dev/null
[ -f keep.txt ] && pass "checkignore keeps non-ignored" || fail "checkignore keeps non-ignored" "keep.txt missing"
[ ! -f debug.log ] && pass "checkignore ignores *.log" || fail "checkignore ignores *.log" "debug.log was restored"

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
