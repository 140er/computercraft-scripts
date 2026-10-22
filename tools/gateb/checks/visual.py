"""Compare native screenshots with reviewed references outside the repository."""
import hashlib
from pathlib import Path
import subprocess
from .model import Blocked


def compare(actual, reference):
    path = Path(reference["path"]).expanduser()
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != reference.get("sha256"):
        raise Blocked("Reviewed visual reference is absent or its hash changed")
    regions = reference.get("regions", [])
    if not regions:
        raise Blocked("Visual reference must name deterministic pixel regions")
    changed = 0
    for region in regions:
        if len(region) != 4 or any(not isinstance(n, int) or n < 0 for n in region) or not all(region[:2]):
            raise Blocked("Invalid visual reference region")
        width, height, x, y = region
        crop = f"{width}x{height}+{x}+{y}"
        pixels = []
        for image in (Path(actual), path):
            result = subprocess.run(["convert", str(image), "-crop", crop, "+repage", "-depth", "8", "rgba:-"], capture_output=True)
            if result.returncode or len(result.stdout) != width*height*4:
                raise Blocked("Native screenshot comparison requires ImageMagick and matching image bounds")
            pixels.append(result.stdout)
        changed += sum(pixels[0][i:i+4] != pixels[1][i:i+4] for i in range(0, len(pixels[0]), 4))
    return changed == 0, changed


def check(ctx, name):
    references = ctx.manifest.get("visual_baselines", {})
    if name not in references:
        raise Blocked(f"No reviewed deterministic pixel reference for {name}")
    okay, changed = compare(ctx.output / name, references[name])
    ctx.record(name + ".comparison.json", {"reference_sha256": references[name]["sha256"], "changed_pixels": changed})
    return okay
