#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '\n' < VERSION)
output_dir="${TOKENBAR_DIST_DIR:-$PWD/dist}"
pkg="$output_dir/TokenBar-$version-arm64.pkg"
for existing in "$pkg" "$pkg.sha256"; do
    if [[ -e "$existing" || -L "$existing" ]]; then
        echo "Preserve existing output: $existing. Set TOKENBAR_DIST_DIR to a fresh directory." >&2
        exit 1
    fi
done
./scripts/build.sh
mkdir -p "$output_dir"
stage=$(mktemp -d "${TMPDIR:-/tmp}/tokenbar-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root"
ditto "$PWD/build/Token Bar.app" "$stage/root/Token Bar.app"
cat > "$stage/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>Token Bar.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><false/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
# Version checking stays off above: Installer compares short versions first and
# would skip replacing a legacy 2.x build. preinstall compares build numbers
# instead, so it ships beside the scripts, read from the exact bundle packaged.
ditto "$PWD/scripts/pkg" "$stage/scripts"
plist="$stage/root/Token Bar.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" > "$stage/scripts/build"
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
if [[ -z "$identifier" ]]; then
    echo "package.sh: CFBundleIdentifier missing from the built bundle. No installer was assembled." >&2
    exit 1
fi
# --scripts quits a running copy before the payload lands and re-registers
# the installed bundle afterwards, so the system resolves this identifier to
# /Applications rather than to a stale copy elsewhere.
args=(--root "$stage/root" --component-plist "$stage/components.plist" --install-location /Applications --identifier "$identifier" --version "$version" --ownership recommended --scripts "$stage/scripts")
if [[ -n "${INSTALLER_SIGNING_IDENTITY:-}" ]]; then args+=(--sign "$INSTALLER_SIGNING_IDENTITY" --timestamp); fi
pkgbuild "${args[@]}" "$pkg"
./scripts/checksum.sh "$pkg"
printf '%s\n' "Installer assembled. Public distribution still requires Developer ID signing and notarization."
