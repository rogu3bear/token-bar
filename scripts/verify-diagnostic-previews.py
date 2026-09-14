#!/usr/bin/env python3
"""Repeat native synthetic diagnostics in fresh processes; never compare motion PNGs as a gate."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--motion-raster", action="store_true", help="Also capture and report native animation raster differences (not a determinism gate)")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
binary = root / "build/Token Bar.app/Contents/MacOS/TokenBar"
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)

def run(pass_dir, name, *arguments):
    with (pass_dir / (name + ".log")).open("w") as log:
        subprocess.run([str(binary), *map(str, arguments)], cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for iteration in ("first", "second"):
    folder = output / iteration
    folder.mkdir()
    run(folder, "data", "--render-data-states", folder / "data")
    for state in ("populated", "empty", "partial", "failed"):
        run(folder, "pages-" + state, "--render-pages-preview", folder / ("pages-" + state), "--sample-state", state, "--layout-matrix")
    run(folder, "history", "--render-history-preview", folder / "history.png")
    run(folder, "compact", "--render-compact-preview", folder / "compact.png")
    run(folder, "welcome", "--render-welcome", folder / "welcome.png")
    run(folder, "motion", "--render-motion-preview", folder / "motion", "--sample-receipts-only")
    if args.motion_raster:
        run(folder, "motion-raster", "--render-motion-preview", folder / "motion-raster")
    # Separate processes in wall time, including displayed relative-age boundaries.
    if iteration == "first":
        time.sleep(2)

first, second = output / "first", output / "second"
paths = sorted(p.relative_to(first) for p in first.rglob("*.png") if "motion-raster" not in p.parts)
assert paths and paths == sorted(p.relative_to(second) for p in second.rglob("*.png") if "motion-raster" not in p.parts), "Diagnostic image sets differ"
differences = [str(p) for p in paths if digest(first / p) != digest(second / p)]
receipt_path = Path("motion/capture.json")
receipt_equal = (first / receipt_path).read_bytes() == (second / receipt_path).read_bytes()
receipt = json.loads((first / receipt_path).read_text())
assert len(receipt["frames"]) == 1920 and receipt["sampleClock"] == "frame / 30"
assert receipt["frames"][0]["frame"] == 0 and receipt["frames"][-1]["frame"] == 1919
raster = None
if args.motion_raster:
    frames = sorted((first / "motion-raster").glob("*.png"))
    assert len(frames) == 3840
    changed = [p.name for p in frames if digest(p) != digest(second / "motion-raster" / p.name)]
    for folder in (first, second):
        assert (folder / "motion-raster/capture.json").read_bytes() == (first / receipt_path).read_bytes(), "Raster pacing changed sample receipt"
    raster = {"compared": len(frames), "different": len(changed), "files": changed,
              "interpretation": "Native SwiftUI/AppKit animation phase is wall-clock paced; raster equality is not the sample determinism contract."}
report = {"binarySHA256": digest(binary), "diagnosticStills": len(paths), "differentStills": differences,
          "motionSamples": len(receipt["frames"]), "motionReceiptIdentical": receipt_equal,
          "nativeAnimationRaster": raster}
(output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
(output / "SHA256SUMS").write_text("".join(digest(first / p) + "  first/" + str(p) + "\n" for p in paths + [receipt_path]))
print(json.dumps({key: value for key, value in report.items() if key != "nativeAnimationRaster"}, indent=2))
if raster:
    print(f"Native animation raster differences: {raster['different']}/{raster['compared']} (reported separately)")
raise SystemExit(bool(differences) or not receipt_equal)
