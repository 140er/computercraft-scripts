from dataclasses import asdict, dataclass, field
from typing import Literal


class Blocked(RuntimeError):
    pass


@dataclass
class Verdict:
    status: Literal["pass", "fail", "blocked"]
    findings: list[str] = field(default_factory=list)
    metrics: dict = field(default_factory=dict)


class Criteria:
    def __init__(self):
        self.failures = []
        self.missing = []

    def require(self, value, message):
        if value is None:
            self.missing.append(message)
        elif not value:
            self.failures.append(message)

    def finish(self, metrics=None):
        return Verdict("fail" if self.failures else "blocked" if self.missing else "pass",
                       self.failures + [f"Missing evidence: {m}" for m in self.missing], metrics or {})


@dataclass
class Result:
    check: str
    commit: str
    status: str
    started_at: str
    wall_seconds: float
    tick_rate: float
    findings: list[str]
    metrics: dict
    evidence: list[str]
    world: str

    def to_dict(self):
        return asdict(self)


def values(v):
    return list(v.values()) if isinstance(v, dict) else list(v or [])


def xyz(p):
    if isinstance(p, (tuple, list)):
        return tuple(p[:3])
    return tuple(p[k] for k in ("x", "y", "z"))


def world_pose(p, frame):
    x, y, z = xyz(p)
    x, z = ((x, z), (-z, x), (-x, -z), (z, -x))[frame["rot"]]
    return x + frame["ox"], y + frame["oy"], z + frame["oz"]


def own_path(journal, frame):
    p = dict(journal["pose"])
    path = {world_pose(p, frame)}
    moves = journal.get("moves", {})
    moves = [moves[k] for k in sorted(moves, key=lambda k: int(k))] if isinstance(moves, dict) else moves
    for move in reversed(moves):
        if move.get("ok") is False:
            continue
        op = move["op"]
        dx, dz = ((0, -1), (1, 0), (0, 1), (-1, 0))[p["f"]]
        if op == "turnLeft": p["f"] = (p["f"] + 1) % 4
        elif op == "turnRight": p["f"] = (p["f"] - 1) % 4
        elif op == "forward": p["x"], p["z"] = p["x"] - dx, p["z"] - dz
        elif op == "back": p["x"], p["z"] = p["x"] + dx, p["z"] + dz
        elif op == "up": p["y"] -= 1
        elif op == "down": p["y"] += 1
        path.add(world_pose(p, frame))
    return path


def lumber_workers(job, legacy_id=None):
    if "turtles" in job:
        return {str(ident): row["turtle"] for ident, row in job["turtles"].items()}
    turtle = job.get("turtle")
    return {str(turtle.get("id", legacy_id)): turtle} if turtle else {}
