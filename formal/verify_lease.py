#!/usr/bin/env python3
"""Check lease event orderings and require scratch Lua defects to fail."""
import argparse
import concurrent.futures
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNC_COMMIT = "d82f456583671350a655ee9c982c126ddd2795d4"
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
        '      lease.status = "expired"\n      if S.persist',
        '      lease.status = "expired"\n      SO.mods.cells.releaseOwner("mine:" .. lease.turtleId)\n      if S.persist',
    ),
    "uncertainty": (
        'if row.uncertain or row.anchor then return nil, "pose uncertain" end',
        '-- scratch: dispatch with an uncertain pose',
    ),
    "restart_restore": (
        'if record.status == "open" then row.open = row.record end',
        '-- scratch: discard restored open work',
    ),
    "recovery_forget": (
        "S.persist(record, true)",
        "S.persist(record)",
    ),
    "callback_once": (
        'S.notify(lease, results)',
        'S.notify(lease, results)\n  S.notify(lease, results)',
    ),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--check-evidence", type=Path, help="reject evidence for different source bytes")
    parser.add_argument("--source", type=Path, default=ROOT / "so-mod-lease.lua")
    args = parser.parse_args()
    lua = shutil.which("lua5.2")
    if lua is None:
        raise SystemExit("lua5.2 is required")
    source_bytes = args.source.resolve().read_bytes()
    source = source_bytes.decode()
    source_hash = hashlib.sha256(source_bytes).hexdigest()
    model_hash = hashlib.sha256((ROOT / "formal/lease_orderings.lua").read_bytes()).hexdigest()
    verifier_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    test_path = ROOT / "tests/so/lease.lua"
    test_source = test_path.read_text()
    test_anchor = r'local evidenceSourceHash = "[0-9a-f]{64}"'
    if args.check_evidence:
        recorded = json.loads(args.check_evidence.read_text())
        if recorded.get("source_sha256") != source_hash:
            raise SystemExit("lease evidence hash differs from source; rerun verification")
        if recorded.get("model_sha256") != model_hash or recorded.get("verifier_sha256") != verifier_hash:
            raise SystemExit("lease evidence differs from verifier or model; rerun verification")
        if f'local evidenceSourceHash = "{source_hash}"' not in test_source:
            raise SystemExit("lease test evidence hash differs from source; rerun verification")
        print("PASS lease evidence and test hashes match source")
        return
    started = time.monotonic()
    evidence = {
        "sync_commit": SYNC_COMMIT,
        "covered_file": "so-mod-lease.lua",
        "source_sha256": source_hash,
        "model_sha256": model_hash,
        "verifier_sha256": verifier_hash,
        "tool": subprocess.check_output([lua, "-v"], stderr=subprocess.STDOUT, text=True).strip(),
        "bounds": {"event_permutations": 40320, "events_per_trace": 8,
                   "workers_with_work": 1, "foreign_sender": 3, "dispatch_attempts": 2,
                   "restarts": 1, "batch_sizes": [1, 16],
                   "foreign_report_modes": ["wrong-id", "wrong-sender", "malformed"],
                   "tick_times_ms": [11000, 11001], "prefix_sharing": True,
                   "restart_event_permutations": 5040, "restart_events_per_trace": 7,
                   "restart_batch_sizes": [1, 16], "restart_traces": 10080,
                   "save_failure_traces": 10, "recovery_traces": 8, "journal_recovery_traces": 3, "parallel_processes": 4,
                   "subprocess_budget_seconds": 55},
        "mutations": [],
    }

    def run(path, witness=None):
        command = [lua, str(ROOT / "formal/lease_orderings.lua"), str(path)]
        if witness:
            command.append(witness)
        remaining = 55 - (time.monotonic() - started)
        if remaining <= 0:
            raise SystemExit("verification exceeded the 55-second budget")
        try:
            return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise SystemExit("verification exceeded the 55-second budget") from error

    partitions = [f"partition:{foreign}:{size}:{grace}"
                  for foreign in ("wrong-id", "wrong-sender", "malformed")
                  for size in (1, 16) for grace in (11000, 11001)]
    partitions += ["restarts:1", "restarts:16", "failures", "recovery", "journal-recovery"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        baselines = list(executor.map(lambda part: run(args.source.resolve(), part), partitions))
    output = "".join(result.stdout + result.stderr for result in baselines)
    baseline_code = next((result.returncode for result in baselines if result.returncode), 0)
    totals = re.findall(r"PASS traces=(\d+) comparisons=(\d+)", output)
    expected_traces = 40320 * 12 + 5040 * 2 + 10 + 8 + 3
    if not baseline_code and (len(totals) != len(partitions) or sum(int(t[0]) for t in totals) != expected_traces):
        raise SystemExit("verification did not enumerate every bounded trace")
    summary = (f"PASS traces={sum(int(t[0]) for t in totals)} "
               f"comparisons={sum(int(t[1]) for t in totals)}; "
               "all legacy schedules, two restarts, acknowledgements, save failures and journal/forget recovery\n")
    evidence["baseline"] = {"exit_code": baseline_code, "output": output, "summary": summary}
    print(output if baseline_code else summary, end="")
    if baseline_code:
        raise SystemExit(baseline_code)
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
        test_source = test_path.read_text()
        if len(re.findall(test_anchor, test_source)) != 1:
            raise SystemExit("lease test evidence anchor changed")
        args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
        test_path.write_text(re.sub(test_anchor,
                                   f'local evidenceSourceHash = "{source_hash}"', test_source))
    print(f"PASS real-source verification and all {len(MUTATIONS)} scratch defects; {evidence['elapsed_seconds']}s")


if __name__ == "__main__":
    main()
