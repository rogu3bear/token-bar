#!/usr/bin/env python3
"""Prepare an isolated native GUI test bundle; launch using the receipt's command.

LaunchServices must start TokenBar directly, with the recorded synthetic arguments.
An exec-based shell wrapper can invalidate the process identity used by MenuBarAgent.
Current preview bundles refuse argument-free launch before starting real monitoring.
This script only prepares; it never launches an app, changes session permissions,
or touches the installed Token Bar bundle.
"""
import argparse
import hashlib
import json
import plistlib
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bundle_layout import EXECUTABLE_NAME, built_app, built_executable

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="New disposable .app path")
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--allowance", choices=["now", "popover"], help="Use shipping synthetic allowance views")
mode.add_argument("--accounts", action="store_true", help="Exercise Accounts navigation with saved plans and hidden Spark windows")
mode.add_argument("--coverage", action="store_true", help="Exercise retained continuity diagnostics with a completed read")
mode.add_argument("--instruments", action="store_true", help="Exercise independent active instruments with a synthetic status item")
mode.add_argument("--recovery", action="store_true", help="Load scanner-created persisted usage and a retained historical gap")
mode.add_argument("--quota", choices=["aged", "stale", "missing", "zero"], help="Exercise synthetic allowance boundaries")
args = parser.parse_args()
preview_arguments = (["--preview-tools", "--sample-width", "900", "--sample-height", "700"]
                     + (["--sample-compact"] if args.allowance == "popover" else [])) if args.allowance else [
                         "--preview-cost-navigation", "--preview-native-interaction", "--sample-state", "failed", "--sample-history"]
if args.accounts:
    preview_arguments = ["--preview-cost-navigation", "--preview-native-interaction", "--sample-state", "populated",
                         "--sample-spark-accounts", "--sample-account-history"]
if args.coverage:
    preview_arguments = ["--preview-cost-navigation", "--preview-native-interaction", "--sample-state", "partial",
                         "--sample-many-diagnostics", "--sample-history"]
if args.instruments:
    preview_arguments = ["--preview-tools", "--sample-instruments"]
if args.recovery:
    preview_arguments = ["--preview-cost-navigation", "--preview-native-interaction", "--sample-recovery",
                         "--sample-recovery-receipt", str(args.output.absolute().with_suffix(".data.json"))]
if args.quota:
    preview_arguments = ["--preview-quota-guard", "--sample-compact", "--sample-active"]
    if args.quota == "stale":
        preview_arguments += ["--sample-stale", "--sample-claude-age", "1800"]
    elif args.quota == "missing":
        preview_arguments += ["--sample-unavailable"]
    elif args.quota == "zero":
        preview_arguments = ["--preview-tools", "--sample-compact", "--sample-zero"]
root = Path(__file__).resolve().parent.parent
source = built_app(root)
output = args.output.absolute()
receipt = output.with_suffix(".receipt.json")
if output.suffix != ".app" or output.exists() or output.is_symlink() or receipt.exists() or receipt.is_symlink():
    parser.error("Output must be a new .app path with no existing receipt")
binary = built_executable(root)
if b"Token Bar preview requires its recorded synthetic launch arguments." not in binary.read_bytes():
    parser.error("Rebuild the app first: this executable lacks the argument-free preview launch guard")
if args.recovery and b"persisted recovery fixture" not in binary.read_bytes():
    parser.error("Rebuild the app first: this executable lacks the persisted recovery fixture")
if args.recovery and output.with_suffix(".data.json").exists():
    parser.error("Recovery data receipt already exists")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
identity = "local.star.TokenBarPreview." + uuid.uuid4().hex
shutil.copytree(source, output)
info_path = output / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier=identity, CFBundleExecutable=EXECUTABLE_NAME, CFBundleName="Token Bar Repair Preview")
info_path.write_bytes(plistlib.dumps(info))
# The copied Mach-O's signature bound the original Info.plist. Reseal this
# disposable copy after changing the bundle identity.
fixture_binary = output / "Contents/MacOS" / EXECUTABLE_NAME
subprocess.run(["codesign", "--force", "--sign", "-", str(fixture_binary)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
def unsigned_sha(path):
    with tempfile.TemporaryDirectory(prefix="tokenbar-preview-signature-") as directory:
        copy = Path(directory) / EXECUTABLE_NAME
        shutil.copy2(path, copy)
        subprocess.run(["codesign", "--remove-signature", str(copy)], check=True)
        return sha(copy)

unsigned = unsigned_sha(binary)
assert unsigned == unsigned_sha(fixture_binary)
receipt.write_text(json.dumps({
    "source": str(source), "bundle": str(output), "bundleIdentifier": identity,
    "sourceBinarySHA256": sha(binary), "fixtureBinarySHA256": sha(fixture_binary),
    "unsignedBinarySHA256": unsigned,
    "arguments": preview_arguments,
    "launch": ["open", "-n", str(output), "--args", *preview_arguments],
    "scope": "Synthetic fixture only; use the recorded LaunchServices arguments, then attach to the running app. Argument-free launch is refused."
}, indent=2) + "\n")
print(str(receipt))
