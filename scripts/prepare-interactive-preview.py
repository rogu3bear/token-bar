#!/usr/bin/env python3
"""Prepare an isolated native GUI test bundle; launch it through macOS LaunchServices.

The executable wrapper fixes synthetic arguments even when a GUI tool relaunches
the app without arguments. This script prepares only; it never launches an app,
changes session permissions, or touches the installed Token Bar bundle.
"""
import argparse
import hashlib
import json
import plistlib
import shlex
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="New disposable .app path")
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--allowance", choices=["now", "popover"], help="Use shipping synthetic allowance views")
mode.add_argument("--accounts", action="store_true", help="Exercise Accounts navigation with saved plans and hidden Spark windows")
args = parser.parse_args()
preview_arguments = (["--preview-tools", "--sample-width", "900", "--sample-height", "700"]
                     + (["--sample-compact"] if args.allowance == "popover" else [])) if args.allowance else [
                         "--preview-cost-navigation", "--preview-native-interaction", "--sample-state", "failed", "--sample-history"]
if args.accounts:
    preview_arguments = ["--preview-cost-navigation", "--preview-native-interaction", "--sample-state", "populated",
                         "--sample-spark-accounts", "--sample-account-history"]
root = Path(__file__).resolve().parent.parent
source = root / "build/Token Bar.app"
output = args.output.absolute()
receipt = output.with_suffix(".receipt.json")
if output.suffix != ".app" or output.exists() or output.is_symlink() or receipt.exists() or receipt.is_symlink():
    parser.error("Output must be a new .app path with no existing receipt")
binary = source / "Contents/MacOS/TokenBar"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
identity = "local.star.TokenBarPreview." + uuid.uuid4().hex
shutil.copytree(source, output)
info_path = output / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier=identity, CFBundleExecutable="PreviewLauncher", CFBundleName="Token Bar Repair Preview")
info_path.write_bytes(plistlib.dumps(info))
launcher = output / "Contents/MacOS/PreviewLauncher"
launcher.write_text('''#!/bin/sh
set -eu
preview_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$preview_dir/TokenBar" ''' + shlex.join(preview_arguments) + "\n")
launcher.chmod(0o755)
# The copied Mach-O's signature bound the original Info.plist. Reseal this
# disposable copy after changing the bundle identity, then sign its launcher.
fixture_binary = output / "Contents/MacOS/TokenBar"
subprocess.run(["codesign", "--force", "--sign", "-", str(fixture_binary)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
def unsigned_sha(path):
    with tempfile.TemporaryDirectory(prefix="tokenbar-preview-signature-") as directory:
        copy = Path(directory) / "TokenBar"
        shutil.copy2(path, copy)
        subprocess.run(["codesign", "--remove-signature", str(copy)], check=True)
        return sha(copy)

unsigned = unsigned_sha(binary)
assert unsigned == unsigned_sha(fixture_binary)
receipt.write_text(json.dumps({
    "source": str(source), "bundle": str(output), "bundleIdentifier": identity,
    "sourceBinarySHA256": sha(binary), "fixtureBinarySHA256": sha(fixture_binary),
    "unsignedBinarySHA256": unsigned, "launcherSHA256": sha(launcher),
    "arguments": preview_arguments,
    "launch": ["open", "-n", str(output)],
    "scope": "Synthetic fixture only; launch requires the supported GUI session context."
}, indent=2) + "\n")
print(str(receipt))
