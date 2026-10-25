#!/bin/sh
# Retry admission refusals for at most 30 minutes. Check results keep their status.
set -u
gateb_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
deadline=$(($(date +%s) + 1800))
while :; do
    python3 "$gateb_dir/run.py" "$@"
    result=$?
    [ "$result" -eq 75 ] || exit "$result"
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || exit 75
    delay=60
    [ "$remaining" -ge "$delay" ] || delay=$remaining
    echo "Gate B admission busy; retrying in ${delay}s" >&2
    sleep "$delay"
    [ "$(date +%s)" -lt "$deadline" ] || exit 75
done
