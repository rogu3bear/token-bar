#!/usr/bin/env python3
"""Exercise the real postinstall reopen flow with isolated command fixtures."""
from pathlib import Path
import os
import subprocess
import tempfile

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
source = Path("scripts/pkg/postinstall").read_text()
with tempfile.TemporaryDirectory(prefix="tokenbar-postinstall-test-") as scratch:
    root = Path(scratch)
    calls = root / "calls"
    commands = {
        LSREGISTER: 'echo "lsregister $*" >> "$TEST_CALLS"',
        "/usr/bin/stat": (
            'if [ "$TEST_STAT_FAIL" = "yes" ]; then exit 1; fi\n'
            'printf "%s\\n" "$TEST_CONSOLE_USER"\n'
        ),
        "/usr/bin/id": (
            'if [ "$TEST_ID_FAIL" = "yes" ]; then exit 1; fi\n'
            'printf "%s\\n" "$TEST_UID"\n'
        ),
        "/bin/launchctl": (
            'echo "launchctl $*" >> "$TEST_CALLS"\n'
            'if [ "$1" = "asuser" ]; then\n'
            '  shift 2\n'
            '  exec "$@"\n'
            'fi\n'
        ),
        "/usr/bin/sudo": (
            'echo "sudo $*" >> "$TEST_CALLS"\n'
            'if [ "$1" = "-u" ]; then\n'
            '  shift 2\n'
            '  exec "$@"\n'
            'fi\n'
        ),
        "/usr/bin/open": (
            'echo "open $*" >> "$TEST_CALLS"\n'
            'exit "${TEST_OPEN_STATUS:-0}"\n'
        ),
    }
    for index, (path, body) in enumerate(commands.items()):
        fixture = root / str(index)
        fixture.write_text("#!/bin/bash\n" + body + "\n")
        fixture.chmod(0o700)
        source = source.replace(path, str(fixture))
    script = root / "postinstall"
    script.write_text(source)

    def run(console="star", uid="501", stat_fail="no", id_fail="no", open_status="0"):
        calls.write_text("")
        env = dict(
            os.environ,
            TEST_CALLS=str(calls),
            TEST_CONSOLE_USER=console,
            TEST_UID=uid,
            TEST_STAT_FAIL=stat_fail,
            TEST_ID_FAIL=id_fail,
            TEST_OPEN_STATUS=open_status,
        )
        result = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True)
        return result.returncode, calls.read_text(), result.stderr

    code, log, error = run()
    assert code == 0, error
    assert "lsregister -f /Applications/Token Bar.app" in log, log
    assert "launchctl asuser 501" in log, log
    assert "sudo -u star" in log, log
    assert "open -a /Applications/Token Bar.app" in log, log
    assert "/Users/" not in log and "Downloads" not in log, log

    code, log, error = run(console="root")
    assert code == 0, error
    assert "lsregister -f /Applications/Token Bar.app" in log, log
    assert "launchctl" not in log and "open -a" not in log, log

    code, log, error = run(stat_fail="yes")
    assert code == 0, error
    assert "launchctl" not in log and "open -a" not in log, log

    code, log, error = run(console="")
    assert code == 0, error
    assert "launchctl" not in log and "open -a" not in log, log

    code, log, error = run(id_fail="yes")
    assert code == 0, error
    assert "launchctl" not in log and "open -a" not in log, log

    code, log, error = run(open_status="1")
    assert code == 0, error
    assert "open -a /Applications/Token Bar.app" in log, log

print("PASS: postinstall registers Applications and reopens for the console user")
print("PASS: postinstall keeps the install successful when reopen cannot run")
