#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

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
