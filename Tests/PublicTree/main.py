"""Check ignored-but-tracked content and credential rejection in a synthetic repo."""
from pathlib import Path
import subprocess
import tempfile

owner = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="tokenbar-public-tree-") as scratch:
    root = Path(scratch)
    def git(*args):
        return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
    def check(expected):
        result = subprocess.run(["python3", str(owner / "scripts/check-public-tree.py")],
                                cwd=root, capture_output=True)
        assert result.returncode == expected, result.stderr.decode()
        return result
    git("init", "--quiet")
    (root / ".gitignore").write_bytes((owner / ".gitignore").read_bytes())
    (root / "README.md").write_text("Synthetic public source\n")
    git("add", ".gitignore", "README.md")
    check(0)
    for name in ["AGENTS.md", "docs/VERIFICATION.md", "site/.env", "ledger.json",
                 "private/note.md", "state.sqlite-wal", "usage.jsonl"]:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic private artifact\n")
        git("add", "--force", name)
        assert b"tracked despite ignore rule" in check(1).stderr
        git("rm", "--cached", "--force", name)
    (root / "site/.env.example").write_text("EXAMPLE_KEY=placeholder\n")
    git("add", "site/.env.example")
    check(0)
    # The index is the publication target; an unstaged ignore edit cannot weaken it.
    ignored = root / 'private/note.md'
    git('add', '--force', 'private/note.md')
    rules = (root / '.gitignore').read_text()
    (root / '.gitignore').write_text(rules.replace('private/\n', ''))
    assert b'ignore rules differ from the index' in check(1).stderr
    (root / '.gitignore').write_text(rules)
    assert b'tracked despite ignore rule' in check(1).stderr
    git('rm', '--cached', '--force', 'private/note.md')
    # A new nested rule is also untrusted until staged, even if root rules match.
    nested = root / 'site/.gitignore'
    nested.write_text('!*.env\n')
    assert b'ignore rules differ from the index' in check(1).stderr
    nested.unlink()
    check(0)
    (root / "config.txt").write_text("ghp_" + "a" * 36)
    git("add", "config.txt")
    result = check(1)
    assert b"GitHub token" in result.stderr and b"a" * 36 not in result.stderr
    git("rm", "--cached", "config.txt")
    # Unstaged private bytes cannot hide a secret already present in the index.
    (root / "config.txt").write_text("sk-" + "z" * 40)
    git("add", "config.txt")
    (root / "config.txt").write_text("clean working copy")
    assert b"provider API key" in check(1).stderr
print("PASS: public-tree guard checks the index, ignored tracked files, examples and redacted secrets")

# Preserve the published basename contract without a single-use wrapper in release.sh.
for script in ('release.sh', 'package.sh', 'verify-release.sh'):
    assert 'TokenBar-$version-arm64.pkg' in (owner / 'scripts' / script).read_text(), script
print('PASS: release, assembly and reproduction retain the published installer basename')
