"""Real-game checks and their evidence evaluators."""

from importlib import import_module

IDS = tuple(f"C{i}" for i in range(1, 15)) + ("C16",)
GROUPS = {
    "mining": ("C5", "C7", "C8", "C10"),
    "screens": ("C3", "C1", "C2", "C4", "C14"),
    "services": ("C6", "C12", "C13"),
    "lifecycle": ("C9", "C11"),
    "updates": ("C16",),
}
ACCELERATED = {"C5", "C6", "C7", "C8"}


def load(check):
    if check not in IDS:
        raise ValueError(f"Unknown check {check}")
    return import_module(f"checks.{check.lower()}")
