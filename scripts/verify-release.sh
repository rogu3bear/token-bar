#!/bin/bash
# Prove that a signed installer was built from a named commit.
#
# North Star condition 6 requires a release to be reproducible from a clean
# clone with the local scripts alone. This performs that proof instead of
# asserting it: it rebuilds the commit in a throwaway checkout and compares the
# compiled code against the bytes actually shipped.
#
# Signatures are deliberately excluded from the comparison. A Developer ID
# signature differs from the ad-hoc signature a clean clone produces, and that
# difference is expected. Complete unsigned payload files and installer
# semantics must match; toolchain differences fail closed.
#
# Usage: scripts/verify-release.sh <commit-ish> <package.pkg>
set -euo pipefail
cd "$(dirname "$0")/.."

commit="${1:-}"
package="${2:-}"
if [ -z "$commit" ] || [ -z "$package" ]; then
    echo "usage: scripts/verify-release.sh <commit-ish> <package.pkg>" >&2
    exit 2
fi
[ -f "$package" ] || { echo "verify-release.sh: no such package: $package" >&2; exit 2; }
# Absolute, because the comparison below runs from throwaway directories.
package=$(cd "$(dirname "$package")" && pwd)/$(basename "$package")
resolved=$(git rev-parse --verify "$commit^{commit}") || {
    echo "verify-release.sh: not a commit: $commit" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/tokenbar-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "Verifying $(basename "$package") against ${resolved:0:12}"

# 1. Distribution properties of the shipped package itself.
if pkgutil --check-signature "$package" 2>/dev/null | grep -q 'Status: signed by a developer certificate'; then
    echo "PASS: package carries a Developer ID installer signature"
else
    fail "package is not signed by a Developer ID installer certificate"
fi
# stapler distinguishes "no ticket" from "could not check". Exit 68 means it
# could not reach Apple, which is a network fault, not evidence about the
# package. Reporting that as a missing ticket would fail a good release, so the
# three outcomes stay separate.
set +e
staple_output=$(xcrun stapler validate "$package" 2>&1)
staple_status=$?
set -e
case "$staple_status" in
    0)  echo "PASS: package carries a stapled notarization ticket" ;;
    68) fail "notarization could not be checked: stapler cannot reach Apple (exit 68). This is a network fault and says nothing about the package; retry when online" ;;
    *)  fail "package has no valid stapled notarization ticket (stapler exit $staple_status): $(printf '%s' "$staple_output" | tail -1)" ;;
esac

# 2. Expand the exact component payload; never choose an arbitrary executable.
pkgutil --expand-full "$package" "$work/shipped" || fail "package could not be expanded"
shipped="$work/shipped/Payload/Token Bar.app"
[ -f "$shipped/Contents/MacOS/TokenBar" ] || fail "expected Token Bar executable is missing"
codesign --verify --deep --strict "$shipped" || fail "shipped app signature is invalid"

# 3. Rebuild the entire unsigned installer using the candidate's own scripts.
git archive "$resolved" | (mkdir -p "$work/src" && tar -x -C "$work/src") \
    || fail "commit could not be materialized"
( cd "$work/src" && env -u APP_SIGNING_IDENTITY -u INSTALLER_SIGNING_IDENTITY -u TOKENBAR_DIST_DIR ./scripts/package.sh ) > "$work/build.log" 2>&1 \
    || { tail -1 "$work/build.log" >&2; fail "commit does not package with its own scripts"; }
version=$(tr -d '\n' < "$work/src/VERSION")
rebuilt_package="$work/src/dist/TokenBar-$version-arm64.pkg"
pkgutil --expand-full "$rebuilt_package" "$work/rebuilt" || fail "rebuilt installer could not be expanded"
rebuilt="$work/rebuilt/Payload/Token Bar.app"

# 4. Remove signatures only from these disposable copies, then compare complete
# payload files and installer semantics. A toolchain difference fails closed.
codesign --remove-signature "$shipped" || fail "could not normalize shipped signature"
codesign --remove-signature "$rebuilt" || fail "could not normalize rebuilt signature"
python3 scripts/compare-release.py "$work/shipped" "$work/rebuilt" || fail "package contents do not reproduce"
echo "PASS: $(basename "$package") unsigned contents reproduce from $resolved; signatures and signing-dependent sizes excluded"
