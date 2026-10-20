import argparse
import hashlib
import json
import shutil
import statistics
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--raw", type=Path, required=True)
parser.add_argument("--sandbox", type=Path, required=True)
parser.add_argument("--server", type=Path, required=True)
parser.add_argument("--world", type=Path, required=True)
parser.add_argument("--run-id", required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write(name, value):
    (args.output / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def crypto_summary(value):
    groups = {}
    for row in value["samples"]:
        groups.setdefault(row["name"], []).append(row)
    return {
        name: {
            "bytes": rows[0]["bytes"],
            "milliseconds": [row["elapsedMs"] for row in rows],
            "medianMs": statistics.median(row["elapsedMs"] for row in rows),
            "maxSliceMs": max(row["longestSliceMs"] for row in rows),
            "yields": sum(row["yields"] for row in rows),
            "passed": sum(row["ok"] for row in rows),
            "samples": len(rows),
        }
        for name, rows in groups.items()
    }


def runtime(computers, count):
    records = {}
    for computer in range(count):
        records[str(computer)] = {
            path.stem: read(path)
            for path in (computers / str(computer) / "results").glob("*.json")
        }
    main = records["0"]
    missing = [name for name in ["crypto", "astar", "randomness", "storage"] if name not in main]
    crypto = main.get("crypto", {})
    crypto_ok = (crypto.get("successful") == 65 and crypto.get("failed") == 0
                 and len(crypto.get("samples", [])) == 65
                 and all(row["ok"] and row["belowTimeout"] for row in crypto["samples"]))
    astar = main.get("astar", {})
    astar_ok = (astar.get("ok") and len(astar.get("samples", [])) == 10
                and all(row["ok"] and row["belowTimeout"] for row in astar["samples"]))
    return {
        "complete": not missing and crypto_ok and bool(astar_ok),
        "missing": missing,
        "crypto": crypto_summary(crypto) if crypto else {},
        "cryptoRejections": crypto.get("rejections", 0),
        "astar": main.get("astar"),
        "randomness": main.get("randomness"),
        "storage": {key: value.get("storage") for key, value in records.items()},
        "records": records,
    }


gate_a = runtime(args.sandbox / "computer", 3)
gate_a.update(runtime="CraftOS-PC 2.8.3", computers=3, mockTurtles=2,
              diskLimit=1000000, gpsHosts=0, sandbox=args.sandbox.name)
gate_a["complete"] = gate_a["complete"] and all(
    row and row["ok"] for row in gate_a["storage"].values()
)
gate_a["screenshots"] = len(list(args.sandbox.rglob("*.png")))
gate_a["status"] = "PASS" if gate_a["complete"] and gate_a["screenshots"] else "FAIL"
write("gateA.json", gate_a)

gate_b = runtime(args.server / "computer", 7)
gate_b.update(runtime="CC:Tweaked 1.120.2 / Cobalt / Minecraft 1.21.1",
              host=f"box run {args.run_id} (disposable, not live)",
              computers=1, turtles=6, diskLimit=1000000, gpsHosts=0)
capture = args.raw / "gateB/capture"
visual_path = capture / "visual-verdict.json"
gate_b["visual"] = read(visual_path) if visual_path.exists() else {
    "complete": False, "reason": "Real-client capture has not completed."
}
gate_b["screenshots"] = len(list(capture.glob("*.png")))
gate_b["video"] = (capture / "p0-probes.mp4").exists()
missing = gate_b["missing"]
for computer, names in {
    "0": ["clock-frozen-1000", "clock-jump-6000", "clock-running-500",
          "detector-anchor", "detector-yaw-west-down", "detector-yaw-east-up",
          "detector-negative-fraction", "detector-range-1024", "detector-crossdim",
          "ar-wall", "ar-open"],
    "1": ["fuel-normal"],
    "2": [f"analog-input-{level}" for level in [0, 1, 7, 15]],
    "3": [f"fuel-{name}" for name in ["automata", "netherite_end_automata",
          "starbound_end_automata", "creative_end_automata", "chunk_vial"]],
    "4": ["ender-received", "normal-received", "ender-crossdim-received"],
    "6": ["fuel-charging", "fuel-without-charger", "fuel-video"],
}.items():
    for name in names:
        if name not in gate_b["records"][computer]:
            missing.append(f"{computer}/{name}")
        elif not gate_b["records"][computer][name]["ok"]:
            missing.append(f"{computer}/{name} failed")
gate_b["unload"] = read(args.world / "unload.json")
before = read(args.world / "unload-boot-before.json")
after = read(args.world / "unload-boot-after.json")
gate_b["unload"]["bootsBefore"] = before["boots"]
gate_b["unload"]["bootsAfter"] = after["boots"]
def value(computer, name):
    return gate_b["records"][str(computer)].get(name, {}).get("value", {})

gate_b["counts"] = {
    "analog": [value(2, f"analog-input-{level}").get("input") for level in [0, 1, 7, 15]],
    "fuelMoves": {
        f"{computer}/{name}": record["value"]["moves"]
        for computer, records in gate_b["records"].items()
        for name, record in records.items()
        if name.startswith("fuel-") and record.get("ok") and "moves" in record.get("value", {})
    },
    "modem": {
        name: sum(row["message"]["probe"] == tag for row in value(4, name).get("messages", []))
        for name, tag in [("ender-received", "ender-512"), ("normal-received", "normal-512"),
                          ("ender-crossdim-received", "ender-crossdim")]
    },
}
counts = gate_b["counts"]
counts_ok = (counts["analog"] == [0, 1, 7, 15]
             and counts["modem"] == {"ender-received": 10, "normal-received": 0, "ender-crossdim-received": 10}
             and all(count == 10 for count in counts["fuelMoves"].values())
             and gate_b["unload"]["quietQueries"] >= 3
             and after["boots"] == before["boots"] + 1)
storage_ok = all(row and row["ok"] and row["capacity"] == 1000000
                 and row["directoryCost"] == 500 and len(row["files"]) == 6
                 and all(file["allocated"] == max(500, file["bytes"])
                         and file["readSize"] == file["bytes"] for file in row["files"])
                 for row in gate_b["storage"].values())
anchor = value(0, "detector-anchor").get("samples", [])
anchor_ok = len(anchor) == 20 and all(
    row.get("anchor") == {"x": 4, "y": -59, "z": 0} for row in anchor
)
frozen = [row["ingame"] for row in value(0, "clock-frozen-1000").get("samples", [])]
jump = [row["ingame"] for row in value(0, "clock-jump-6000").get("samples", [])]
running = [row["ingame"] for row in value(0, "clock-running-500").get("samples", [])]
clock_ok = (len(frozen) == len(jump) == len(running) == 5
            and len(set(frozen)) == len(set(jump)) == 1
            and jump[0] - frozen[0] == 18000000
            and all(right > left for left, right in zip(running, running[1:])))
gate_b["checks"] = {"counts": counts_ok, "storage": storage_ok, "anchor": anchor_ok,
                    "clock": clock_ok}
gate_b["complete"] = (gate_b["complete"] and not missing
                      and gate_b["visual"]["complete"] and gate_b["video"]
                      and gate_b["unload"]["heartbeatStopped"]
                      and all(gate_b["checks"].values()))
gate_b["status"] = "PASS" if gate_b["complete"] else "FAIL"
write("gateB.json", gate_b)

for source, name in [(args.raw / "unit-final.log", "unit.log"),
                     (args.raw / "jar-sha256.txt", "jar-sha256.txt"),
                     (args.raw / "host-load.json", "host-load.json")]:
    shutil.copyfile(source, args.output / name)
for source, name in [(args.server / "computer", "computer-disks.zip"),
                     (args.sandbox, "craftos-run.zip")]:
    with zipfile.ZipFile(args.output / name, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(source))
for directory in ["logs", "config"]:
    source = args.server / directory
    if source.exists():
        shutil.copytree(source, args.output / directory, dirs_exist_ok=True)
if (args.server / "rcon.txt").exists():
    shutil.copyfile(args.server / "rcon.txt", args.output / "rcon.txt")
for name in ["closed.json", "transport-retries.json", "inventory-rcon.txt"]:
    if (args.server / name).exists():
        shutil.copyfile(args.server / name, args.output / name)
if capture.exists():
    shutil.copytree(capture, args.output / "capture", dirs_exist_ok=True)
failed = args.output / "failed-attempts"
failed.mkdir(exist_ok=True)
for trial in (args.raw / "gateA").glob("sandbox-*"):
    if trial == args.sandbox:
        continue
    with zipfile.ZipFile(failed / (trial.name + ".zip"), "w", zipfile.ZIP_DEFLATED) as archive:
        for path in trial.rglob("*"):
            if path.is_file() and path.suffix in [".json", ".log"]:
                archive.write(path, path.relative_to(trial))
for directory in ["debug", "repair", "gateB/final-probes", "gateB/upgrade-retry"]:
    source = args.raw / directory
    with zipfile.ZipFile(failed / (source.name + ".zip"), "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source.rglob("*"):
            if path.is_file() and path.suffix in [".json", ".log", ".txt"]:
                archive.write(path, path.relative_to(source))
write("sha256.json", {
    str(path.relative_to(args.output)).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(args.output.rglob("*"))
    if path.is_file() and path.name != "sha256.json"
})
print(json.dumps({"gateA": gate_a["status"], "gateB": gate_b["status"], "missing": missing}))
