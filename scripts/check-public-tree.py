#!/usr/bin/env python3
"""Check staged content before committing or publishing the public repository.

Uses the Git index, not just untracked-file ignore behavior. This is a focused
guard for private artifacts and common credentials, not a complete secret audit.
"""
import re
import subprocess
import sys
from pathlib import Path


def git(*args, data=None, allowed=(0,)):
    result = subprocess.run(["git", *args], input=data, capture_output=True)
    if result.returncode not in allowed:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout


def check():
    files = git("ls-files", "--cached", "-z").split(b"\0")
    files = [name for name in files if name]
    if not files:
        print("FAIL: no staged files to inspect", file=sys.stderr)
        return 1
    contents = {name.decode(): git("show", ":" + name.decode()) for name in files}
    # check-ignore evaluates files on disk even with --no-index. Fail closed
    # unless every applicable ignore file exactly matches the staged rules.
    # Include untracked nested ignore files that could override a parent rule.
    ignore_paths = {str(parent / ".gitignore")
                    for name in contents for parent in Path(name).parents}
    for name in sorted(ignore_paths):
        path = Path(name)
        staged = contents.get(name)
        local = path.read_bytes() if path.is_file() else None
        if staged != local:
            print(f"FAIL: {name}: ignore rules differ from the index; stage or restore them", file=sys.stderr)
            return 1
    ignored = git("check-ignore", "--no-index", "-z", "--stdin",
                  data=b"\0".join(files) + b"\0", allowed=(0, 1))
    problems = [(name.decode(), "tracked despite ignore rule")
                for name in ignored.split(b"\0") if name]
    patterns = {
        "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
        "GitHub token": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
        "provider API key": rb"\bsk-(?:proj-|ant-api\d+-)?[A-Za-z0-9_-]{32,}",
        "local home path": rb"/Users/(?!x/|example/|test/|Shared/)[A-Za-z0-9_.-]+/",
    }
    for raw in files:
        name = raw.decode()
        content = contents[name]
        if b"\0" in content:
            continue
        for label, pattern in patterns.items():
            if re.search(pattern, content):
                problems.append((name, label))
    for name, reason in problems:
        # Never print the matching secret or private content.
        print(f"FAIL: {name}: {reason}", file=sys.stderr)
    if problems:
        return 1
    print(f"PASS: {len(files)} staged files; no ignored artifacts or credential markers")
    return 0


if __name__ == "__main__":
    sys.exit(check())
