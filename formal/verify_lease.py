#!/usr/bin/env python3
"""Check lease event orderings and require scratch Lua defects to fail."""
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNC_COMMIT = "0f73a4ea74815bc21158585a498da446f5072034"
MUTATIONS = {
    "dispatch": (
        'if row.open then return nil, "busy" end',
        '-- scratch: allow replacement of an open lease',
    ),
    "report_integrity": (
        'or body.lease ~= lease.id then',
        'then -- scratch: accept a foreign lease id',
    ),
    "reservation_retention": (
        'lease.status = "expired"',
        'lease.status = "expired"\n      SO.mods.cells.releaseOwner(lease.id)',
    ),
    "uncertainty": (
        'if row.uncertain or row.anchor then return nil, "pose uncertain" end',
        '-- scratch: dispatch with an uncertain pose',
    ),
    "callback_once": (
        'S.notify(lease, results)',
        'S.notify(lease, results)\n  S.notify(lease, results)',
    ),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--source", type=Path, default=ROOT / "so-mod-lease.lua")
    args = parser.parse_args()
    lua = shutil.which("lua5.2")
    if lua is None:
        raise SystemExit("lua5.2 is required")
    source = args.source.resolve().read_text()
    started = time.monotonic()
    evidence = {
        "sync_commit": SYNC_COMMIT,
        "covered_file": "so-mod-lease.lua",
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "tool": subprocess.check_output([lua, "-v"], stderr=subprocess.STDOUT, text=True).strip(),
        "bounds": {"event_permutations": 40320, "events_per_trace": 8,
                   "workers_with_work": 1, "foreign_sender": 3, "dispatch_attempts": 2,
                   "restarts": 1, "batch_sizes": [1, 16],
                   "foreign_report_modes": ["wrong-id", "wrong-sender", "malformed"],
                   "tick_times_ms": [11000, 11001]},
        "mutations": [],
    }

    def run(path, witness=None):
        command = [lua, str(ROOT / "formal/lease_orderings.lua"), str(path)]
        if witness:
            command.append(witness)
        remaining = 55 - (time.monotonic() - started)
        if remaining <= 0:
            raise SystemExit("verification exceeded the 55-second budget")
        return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=remaining)

    baseline = run(args.source.resolve())
    evidence["baseline"] = {"exit_code": baseline.returncode, "output": baseline.stdout + baseline.stderr}
    print(baseline.stdout + baseline.stderr, end="")
    if baseline.returncode:
        raise SystemExit(baseline.returncode)
    with tempfile.TemporaryDirectory(prefix="verify-lease-") as scratch:
        for property_name, (before, after) in MUTATIONS.items():
            if source.count(before) != 1:
                raise SystemExit(f"mutation anchor changed for {property_name}; resync the model")
            path = Path(scratch) / f"{property_name}.lua"
            path.write_text(source.replace(before, after, 1))
            result = run(path, property_name)
            output = result.stdout + result.stderr
            if result.returncode == 0 or f"PROPERTY {property_name} " not in output:
                raise SystemExit(f"scratch defect escaped {property_name}:\n{output}")
            evidence["mutations"].append({"property": property_name, "exit_code": result.returncode,
                                          "before": before, "after": after, "counterexample": output})
            print(f"CAUGHT scratch Lua mutation: {property_name}")
    evidence["scratch_removed"] = not Path(scratch).exists()
    evidence["elapsed_seconds"] = round(time.monotonic() - started, 3)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"PASS real-source verification and all 5 scratch defects; {evidence['elapsed_seconds']}s")


if __name__ == "__main__":
    main()
