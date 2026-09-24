#!/bin/bash
set -euo pipefail

# Set sane PATH: standard system paths + common tool locations
# Ensures pkgutil (/usr/sbin), bun, and other tools are findable
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}"

cd "$(dirname "$0")/.."

# Check prerequisites early
echo "==> Checking prerequisites"

if ! command -v swift >/dev/null 2>&1 && ! command -v xcodebuild >/dev/null 2>&1; then
    echo "ERROR: Swift toolchain not found. Install Xcode command-line tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
    echo "ERROR: bun not found. Install from https://bun.sh or:" >&2
    echo "  curl -fsSL https://bun.sh/install | bash" >&2
    echo "Then ensure ~/.bun/bin is in PATH or restart your shell." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. Install Python 3." >&2
    exit 1
fi

echo "✓ Prerequisites available: swift, bun, python3"
echo

echo "==> Local CI: Running all project checks"
echo

echo "==> [1/3] Native Swift tests"
./scripts/test.sh
echo "✓ Native tests passed"
echo

echo "==> [2/3] Site tests and build"
(cd site && bun test && bun run build)
echo "✓ Site tests and build passed"
echo

echo "==> [3/3] Public tree check"
python3 scripts/check-public-tree.py
echo "✓ Public tree check passed"
echo

echo "==> All checks passed"
