#!/bin/sh
# tests/run.lua may only gain lines at the end. A missing file under tests/ fails.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: tools/check-scope.sh <base-rev> <head-rev>" >&2
  exit 2
fi

base=$1
head=$2
cd "$(git rev-parse --show-toplevel)"

rc=0
base_file=$(mktemp)
head_file=$(mktemp)
trap 'rm -f "$base_file" "$head_file"' EXIT

if ! git cat-file -e "$base:tests/run.lua" 2>/dev/null; then
  echo "FAIL tests/run.lua is missing on $base"
  rc=1
elif ! git cat-file -e "$head:tests/run.lua" 2>/dev/null; then
  echo "FAIL tests/run.lua is missing on $head"
  rc=1
else
  git cat-file -p "$base:tests/run.lua" > "$base_file"
  git cat-file -p "$head:tests/run.lua" > "$head_file"
  if [ ! -s "$base_file" ]; then
    echo "FAIL tests/run.lua is empty on $base"
    rc=1
  elif ! awk '
    NR == FNR { base[NR] = $0; n = NR; next }
    FNR <= n && $0 != base[FNR] {
      printf "FAIL tests/run.lua line %d was removed or reordered\n", FNR
      bad = 1
      exit
    }
    END {
      if (bad) exit 1
      if (FNR < n) {
        print "FAIL tests/run.lua is shorter than the base"
        exit 1
      }
      printf "PASS tests/run.lua append-only (%d new lines)\n", FNR - n
    }
  ' "$base_file" "$head_file"; then
    rc=1
  fi
fi

set +e
deleted=$(git diff --no-renames --name-only --diff-filter=D "$base" "$head" -- tests)
diff_rc=$?
set -e
if [ "$diff_rc" -gt 1 ]; then
  echo "FAIL git diff exited $diff_rc"
  exit "$diff_rc"
fi
if [ -n "$deleted" ]; then
  echo "FAIL deleted test file:"
  printf '%s\n' "$deleted"
  rc=1
else
  echo "PASS no test file deleted"
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS check-scope"
else
  echo "FAIL check-scope"
fi
exit "$rc"
