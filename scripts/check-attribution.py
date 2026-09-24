#!/usr/bin/env python3
"""Run the former required attribution check locally for an exact Git range."""
import argparse
import re
import subprocess
import sys


FORBIDDEN = re.compile(
    r"cursoragent@cursor\.com|@cursor\.com|co-authored-by:\s*cursor|"
    r"signed-off-by:\s*cursor|made[- ]with[\s:=.\-\[(]*cursor|"
    r"generated\s+with.*cursor|^cursor\s*$|^cursor agent$|cursorbot",
    re.IGNORECASE | re.MULTILINE,
)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args()
    base = git("rev-parse", "--verify", "--end-of-options", args.base + "^{commit}")
    head = git("rev-parse", "--verify", "--end-of-options", args.head + "^{commit}")
    commits = git("rev-list", "--no-merges", base + ".." + head).splitlines()
    rejected = []
    for commit in commits:
        metadata = git("show", "-s", "--format=%an%n%ae%n%cn%n%ce%n%s%n%b", commit)
        if any(FORBIDDEN.search(line) for line in metadata.splitlines()):
            rejected.append(commit)
    if rejected:
        for commit in rejected:
            print("Forbidden attribution in " + commit, file=sys.stderr)
        return 1
    print(f"PASS: local attribution check, {len(commits)} commits, {base}..{head}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
