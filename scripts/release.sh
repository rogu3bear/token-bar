#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${APP_SIGNING_IDENTITY:?Set the Developer ID Application identity}"
: "${INSTALLER_SIGNING_IDENTITY:?Set the Developer ID Installer identity}"
: "${NOTARY_PROFILE:?Set the Keychain notarytool profile name, not a password}"
version=$(tr -d '\n' < VERSION)
export TOKENBAR_DIST_DIR="${TOKENBAR_DIST_DIR:-$PWD/dist}"
pkg="$TOKENBAR_DIST_DIR/TokenBar-$version-arm64.pkg"
receipt="$TOKENBAR_DIST_DIR/notarization-$version.json"
for existing in "$receipt" "$pkg" "$pkg.sha256"; do
    if [[ -e "$existing" || -L "$existing" ]]; then
        echo "Preserve and inspect existing release output: $existing. Use a fresh TOKENBAR_DIST_DIR for a new attempt." >&2
        exit 1
    fi
done
./scripts/test.sh
(cd site && bun test)
./scripts/package.sh
xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$receipt"
python3 - "$receipt" <<'PY'
import json
import sys
from pathlib import Path
receipt = json.loads(Path(sys.argv[1]).read_text())
if receipt.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Preserve the receipt; do not publish.')
PY
xcrun stapler staple "$pkg"
# Stapling rewrote the package, so package.sh's sidecar is now stale. Re-hash
# before the remaining checks: one of them can fail for reasons that say nothing
# about the package (stapler exit 68 is a network fault), and the guard above
# refuses a rerun, so the preserved output must already be consistent.
./scripts/checksum.sh "$pkg"
xcrun stapler validate "$pkg"
pkgutil --check-signature "$pkg"
spctl --assess --type install --verbose=2 "$pkg"
printf '%s\n' "Signed, notarized installer assembled. Run verify-release.sh against the exact source commit before publication."
