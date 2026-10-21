"""Local hooks for jars that are not published.

turtlebattery, recipe_index and turtlematicfix are named here so a caller
with a private copy can pass a filesystem path. This module does not
download them and it stores no URL for them.
"""

import hashlib
from pathlib import Path

from .errors import FixtureError

CUSTOM_MODS = ("turtlebattery", "recipe_index", "turtlematicfix")

PUBLIC_MODS = {
    "neoforge": {
        "version": "21.1.259",
        "url": "https://maven.neoforged.net/releases/net/neoforged/neoforge/21.1.259/neoforge-21.1.259-installer.jar",
        "sha256": "bb971287ab44fc43f27da77ac34e263a3885d73fb842ceeb20ee5c517ff4378c",
    },
    "cc-tweaked": {
        "version": "1.120.2",
        "minecraft": "1.21.1",
        "loader": "neoforge",
        "filename": "cc-tweaked-1.21.1-forge-1.120.2.jar",
        "url": "https://cdn.modrinth.com/data/gu7yAYhd/versions/1ewzHZYg/cc-tweaked-1.21.1-forge-1.120.2.jar",
        "sha256": "e8651fe24b384e925e563c9ad077644744474e2e7c0adb8e6d5b4757598dce9f",
    },
}


def custom_mod_status(paths=None):
    """Report which private jars the caller supplied. Missing jars stay absent."""
    paths = paths or {}
    if not isinstance(paths, dict):
        raise FixtureError("custom mod paths must be a mapping of name to local file")
    unknown = sorted(set(paths) - set(CUSTOM_MODS))
    if unknown:
        raise FixtureError("unknown custom mod %s" % ", ".join(unknown))
    status = {}
    for name in CUSTOM_MODS:
        raw = paths.get(name)
        if raw in (None, ""):
            status[name] = {"present": False, "public": False, "path": None, "sha256": None}
            continue
        path = Path(raw)
        if not path.is_file():
            status[name] = {"present": False, "public": False, "path": str(path), "sha256": None}
            continue
        status[name] = {
            "present": True,
            "public": False,
            "path": str(path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    return status
