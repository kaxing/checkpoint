#!/bin/bash
# Benchmark: check vs git stash
# Tests save/restore latency on realistic source trees

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="${1:-$SCRIPT_DIR/../zig-out/bin/check}"
CHECK="$(cd "$(dirname "$CHECK")" && pwd)/$(basename "$CHECK")"

if [ ! -x "$CHECK" ]; then
    echo "error: check binary not found at $CHECK"
    echo "run: make build"
    exit 1
fi

# --- Setup ---

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

SMALL="$TMPDIR/small"   # ~50 files, typical LLM project
MEDIUM="$TMPDIR/medium"  # ~500 files, medium codebase
LARGE="$TMPDIR/large"   # ~2000 files, large project

generate_tree() {
    local dir="$1" count="$2"
    mkdir -p "$dir/src" "$dir/lib" "$dir/test" "$dir/docs"
    for i in $(seq 1 "$count"); do
        # Distribute across subdirs
        case $((i % 4)) in
            0) subdir="src" ;;
            1) subdir="lib" ;;
            2) subdir="test" ;;
            3) subdir="docs" ;;
        esac
        # Realistic source file sizes: 1-20KB
        dd if=/dev/urandom bs=1024 count=$((RANDOM % 20 + 1)) 2>/dev/null | base64 > "$dir/$subdir/file_$i.zig"
    done
}

apply_edits() {
    local dir="$1"
    # Modify ~5% of files (simulates LLM making changes)
    local files=($(find "$dir" -name "*.zig" | head -n $(($(find "$dir" -name "*.zig" | wc -l) / 20 + 1))))
    for f in "${files[@]}"; do
        echo "// edited by LLM agent" >> "$f"
    done
    # Add 1 new file
    echo "pub fn new_function() void {}" > "$dir/src/new_module.zig"
}

time_ms() {
    # Returns elapsed time in milliseconds
    local start end
    start=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    eval "$1"
    end=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    echo $(( (end - start) / 1000000 ))
}

# macOS doesn't have date +%s%N, use perl
if ! date +%s%N &>/dev/null; then
    time_ms() {
        local start end
        start=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
        eval "$1"
        end=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000')
        echo $(( end - start ))
    }
fi

bench_scenario() {
    local name="$1" dir="$2" file_count="$3"

    echo ""
    echo "=== $name ($file_count files) ==="
    echo ""

    # --- check ---
    local check_dir="$TMPDIR/check_$name"
    cp -r "$dir" "$check_dir"
    cd "$check_dir"

    # First save (cold)
    local check_save1=$(time_ms "$CHECK --name 'initial' >/dev/null")

    # Apply edits
    apply_edits "$check_dir"

    # Second save (warm, with dedup)
    local check_save2=$(time_ms "$CHECK --name 'after-edit' >/dev/null")

    # Restore
    local check_restore=$(time_ms "$CHECK restore 1 >/dev/null")

    # --- git stash ---
    local git_dir="$TMPDIR/git_$name"
    cp -r "$dir" "$git_dir"
    cd "$git_dir"
    git init -q
    git add -A
    git commit -q -m "initial" --no-gpg-sign

    # Apply same edits
    apply_edits "$git_dir"

    # git stash (save)
    local git_save=$(time_ms "git stash -q")

    # git stash pop (restore)
    local git_restore=$(time_ms "git stash pop -q")

    # Apply edits again for second stash measurement
    apply_edits "$git_dir"
    local git_save2=$(time_ms "git stash -q")

    # Print results
    printf "%-20s %8s %8s\n"    ""           "check"   "git"
    printf "%-20s %7dms %8s\n"  "save (cold)"    "$check_save1" "-"
    printf "%-20s %7dms %7dms\n" "save (warm)"    "$check_save2" "$git_save"
    printf "%-20s %7dms %7dms\n" "restore"         "$check_restore" "$git_restore"

    cd "$TMPDIR"
}

echo "Generating test data..."
generate_tree "$SMALL" 50
generate_tree "$MEDIUM" 500
generate_tree "$LARGE" 2000
echo "Done."

bench_scenario "small"  "$SMALL"  50
bench_scenario "medium" "$MEDIUM" 500
bench_scenario "large"  "$LARGE"  2000

echo ""
echo "Notes:"
echo "  - check save (cold): first snapshot, no dedup possible"
echo "  - check save (warm): second snapshot, ~95% chunks deduped"
echo "  - git stash: requires existing repo with initial commit"
echo "  - times in milliseconds, lower is better"
