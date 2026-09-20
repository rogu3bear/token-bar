"""Exercise the real preinstall flow with isolated process-command fixtures."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

swift = Path("Sources/Stores/SingleInstance.swift").read_text()
match = re.search(r'static let installedPath = "([^"]+)"', swift)
assert match, "DuplicateScan.installedPath must name the Applications bundle"
installed_app = match.group(1)
preinstall = Path("scripts/pkg/preinstall").read_text()
assert f'installed_app="{installed_app}"' in preinstall, "preinstall must stop the copy DuplicateScan calls installed"
assert 'installed_info="$installed_app/Contents/Info.plist"' in preinstall
assert 'target="$installed_app/Contents/MacOS/$executable"' in preinstall
assert installed_app in Path("scripts/pkg/postinstall").read_text(), "postinstall must register the same Applications bundle"
source = preinstall
with tempfile.TemporaryDirectory(prefix="tokenbar-installer-test-") as scratch:
    root = Path(scratch)
    commands = {
        "/usr/bin/pgrep": 'printf "123\\n"',
        "/bin/ps": 'printf "%s\\n" "$TEST_PROCESS_PATH"',
        "/bin/kill": 'echo "$*" >> "$TEST_CALLS"; [ "$1" != "-0" ] || [ "$TEST_STILL_RUNNING" = "yes" ]',
        "/bin/sleep": 'exit 0',
        "/usr/libexec/PlistBuddy": 'if [ -f "$TEST_INSTALLED_BUILD_FILE" ]; then cat "$TEST_INSTALLED_BUILD_FILE"; else exit 1; fi',
    }
    for index, (path, body) in enumerate(commands.items()):
        fixture = root / str(index)
        fixture.write_text("#!/bin/bash\n" + body + "\n")
        fixture.chmod(0o700)
        source = source.replace(path, str(fixture))
    installed_plist = root / "Installed Info.plist"
    source = source.replace('installed_info="$installed_app/Contents/Info.plist"', f'installed_info="{installed_plist}"')
    script = root / "preinstall"
    script.write_text(source)
    calls = root / "calls"
    installed_build = root / "installed-build"
    def run(process, running="no", volume="/", installed=None, incoming="30105"):
        calls.write_text("")
        installed_plist.unlink(missing_ok=True); installed_build.unlink(missing_ok=True)
        if installed is not None:
            installed_plist.write_text("fixture")
            installed_build.write_text(installed + "\n")
        build = root / "build"
        build.unlink(missing_ok=True)
        if incoming is not None:
            build.write_text(incoming + "\n")
        env = dict(os.environ, TEST_PROCESS_PATH=process, TEST_CALLS=str(calls), TEST_STILL_RUNNING=running,
                   TEST_INSTALLED_BUILD_FILE=str(installed_build))
        result = subprocess.run(["/bin/bash", str(script), "package", "/Applications", volume], env=env, capture_output=True, text=True)
        return result.returncode, calls.read_text(), result.stderr
    installed = installed_app + "/Contents/MacOS/TokenBar"
    code, log, _ = run("/tmp/Token Bar.app/Contents/MacOS/TokenBar")
    assert code == 0 and not log, "Development copies must not be signalled"
    code, log, _ = run(installed)
    assert code == 0 and log.startswith("-TERM 123\n"), "Stop the exact installed executable"
    code, log, error = run(installed, running="yes")
    assert code == 1 and "Quit Token Bar" in error and "-KILL" not in log, "Do not replace a running app or force-kill"
    code, log, _ = run(installed, volume="/Volumes/Other")
    assert code == 1 and not log, "Reject other volumes before touching processes"
    code, log, _ = run(installed, installed="20208", incoming="30105")
    assert code == 0 and log.startswith("-TERM 123\n"), "A legacy 2.x development build is replaced"
    code, log, _ = run(installed, installed="30105", incoming="30105")
    assert code == 0, "Reinstalling the same build repairs in place"
    code, log, _ = run(installed, installed="30110", incoming="30111")
    assert code == 0 and log.startswith("-TERM 123\n"), "The successor can replace the installed development build"
    code, log, error = run(installed, installed="30106", incoming="30105")
    assert code == 1 and "newer Token Bar" in error and "30106" in error and not log, "Refuse a downgrade loudly, before touching processes"
    code, log, _ = run(installed, installed=None, incoming="30105")
    assert code == 0, "A fresh install has nothing to compare"
    code, log, _ = run(installed, installed="not-a-number", incoming="30105")
    assert code == 0, "An unreadable installed build is treated as legacy, not as newer"
    code, log, error = run(installed, installed="20208", incoming=None)
    assert code == 1 and "build number" in error and not log, "A package without its build number fails closed"
print("PASS: installer targets only Applications, spares other copies, fails on busy target and rejects other volumes")
print("PASS: installer replaces legacy 2.x builds, reinstalls in place, and refuses a newer installed build loudly before stopping it")
