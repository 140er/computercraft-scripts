"""Read-only admission checks before requesting native Minecraft processes."""
import os
import fcntl
from contextlib import contextmanager
from pathlib import Path
import re
import time

from .model import Blocked


def full_local_suite(locks, slots, command):
    pattern = r"\bFLOCK\s+\S+\s+\S+\s+(\d+)\s+([0-9a-f]+):([0-9a-f]+):(\d+)"
    for match in re.finditer(pattern, locks):
        pid, major, minor, inode = match.groups()
        if int(pid) == os.getpid():
            continue
        slot = slots.get((int(major, 16), int(minor, 16), int(inode)))
        if slot is None:
            continue
        argv = command(int(pid))
        if any(arg == "--shards" or arg.startswith("--shards=") for arg in argv):
            return slot
        if any(arg == "--part" or arg.startswith("--part=") for arg in argv):
            continue
        if slot == "test-suite.lock" and any(Path(arg).name == "keeper.py" for arg in argv):
            continue
        return slot
    return None


def record_load_wait(ctx, seconds):
    ctx.load_wait_seconds = getattr(ctx, "load_wait_seconds", 0) + seconds
    ctx.record("load-wait.json", {"load_wait_seconds": round(ctx.load_wait_seconds, 3)})


def admit(proc=Path("/proc"), work=None, *, timeout=300, on_wait=None, check_load=True):
    load = None
    start = time.monotonic()
    waited = False
    try:
        while check_load:
            load = os.getloadavg()[0]
            if load < 8:
                break
            remaining = timeout - (time.monotonic() - start)
            if remaining <= 0:
                raise Blocked(f"Native run refused: load1={load:.2f} must be below 8")
            waited = True
            time.sleep(min(5, remaining))
    finally:
        if on_wait is not None:
            on_wait(time.monotonic() - start if waited else 0)
    work = work or Path.home() / "work"
    slots = {}
    for name in ("test-suite.lock", "test-suite-local-2.lock"):
        path = work / name
        if path.exists():
            stat = path.stat()
            slots[(os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)] = name
    def command(pid):
        try:
            return (proc / str(pid) / "cmdline").read_bytes().decode(errors="replace").strip("\0").split("\0")
        except OSError:
            return []
    try:
        active = full_local_suite((proc / "locks").read_text(), slots, command)
    except OSError as error:
        raise Blocked("Cannot verify local test-suite admission from /proc/locks") from error
    if active:
        raise Blocked(f"Native run refused: {active} is held by a full or unclassified local test run")
    return {"load1": load, "heavy_local_suite": False}


@contextmanager
def reserve_local_slot(work=None):
    work = work or Path.home() / "work"
    work.mkdir(parents=True, exist_ok=True)
    with (work / "test-suite-local-2.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Blocked("Native run refused: a local suite acquired local-2 before reservation") from error
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
