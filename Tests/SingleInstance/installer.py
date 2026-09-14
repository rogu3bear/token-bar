"""Exercise the real preinstall flow with isolated process-command fixtures."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path("scripts/pkg/preinstall").read_text()
with tempfile.TemporaryDirectory(prefix="tokenbar-installer-test-") as scratch:
    root = Path(scratch)
    commands = {
        "/usr/bin/pgrep": 'printf "123\\n"',
        "/bin/ps": 'printf "%s\\n" "$TEST_PROCESS_PATH"',
        "/bin/kill": 'echo "$*" >> "$TEST_CALLS"; [ "$1" != "-0" ] || [ "$TEST_STILL_RUNNING" = "yes" ]',
        "/bin/sleep": 'exit 0',
    }
    for index, (path, body) in enumerate(commands.items()):
        fixture = root / str(index)
        fixture.write_text("#!/bin/bash\n" + body + "\n")
        fixture.chmod(0o700)
        source = source.replace(path, str(fixture))
    script = root / "preinstall"
    script.write_text(source)
    calls = root / "calls"
    def run(process, running="no", volume="/"):
        calls.write_text("")
        env = dict(os.environ, TEST_PROCESS_PATH=process, TEST_CALLS=str(calls), TEST_STILL_RUNNING=running)
        result = subprocess.run(["/bin/bash", str(script), "package", "/Applications", volume], env=env, capture_output=True, text=True)
        return result.returncode, calls.read_text(), result.stderr
    installed = "/Applications/Token Bar.app/Contents/MacOS/TokenBar"
    code, log, _ = run("/tmp/Token Bar.app/Contents/MacOS/TokenBar")
    assert code == 0 and not log, "Development copies must not be signalled"
    code, log, _ = run(installed)
    assert code == 0 and log.startswith("-TERM 123\n"), "Stop the exact installed executable"
    code, log, error = run(installed, running="yes")
    assert code == 1 and "Quit Token Bar" in error and "-KILL" not in log, "Do not replace a running app or force-kill"
    code, log, _ = run(installed, volume="/Volumes/Other")
    assert code == 1 and not log, "Reject other volumes before touching processes"
print("PASS: installer targets only Applications, spares other copies, fails on busy target and rejects other volumes")
