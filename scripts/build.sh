#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/sources.sh
version=$(tr -d '\n' < VERSION)
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
  echo 'build.sh: VERSION must be major.minor.patch, with minor and patch below 100' >&2
  exit 1
fi
# The public version sequence starts at 0.1.0. A fixed build epoch keeps it
# newer than the development 2.x builds (202xx), preserving upgrade ordering.
build_number=$(printf '%s' "$version" | awk -F. '{printf "%d", 30000+($1*10000)+($2*100)+$3}')
if [ -z "$build_number" ] || [ "$build_number" -le 0 ]; then
  echo "build.sh: VERSION '$version' does not yield a usable CFBundleVersion" >&2
  exit 1
fi
mkdir -p "$PWD/build"
output="$PWD/build/Token Bar.app"
stage=$(mktemp -d "$PWD/build/.token-bar-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Token Bar.app"
read_into APP_SOURCES < <(app_sources)
# Swift runtime diagnostics can encode source-path lengths even in optimized
# code. Keep compiler inputs stable across checkout and release archive paths.
for index in "${!APP_SOURCES[@]}"; do
  APP_SOURCES[$index]="${APP_SOURCES[$index]#"$PWD"/}"
done
discovered=$(discover_sources | grep -c . || true)
if [ "${#APP_SOURCES[@]}" -eq 0 ]; then
  echo "build.sh: no sources discovered under Sources/" >&2
  exit 1
fi
printf 'Compiling %s of %s discovered sources (%s explicitly excluded)\n' \
  "${#APP_SOURCES[@]}" "$discovered" "$((discovered - ${#APP_SOURCES[@]}))"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp Assets/TokenBar.icns "$app/Contents/Resources/TokenBar.icns"
cp Assets/claude-statusline-relay.sh "$app/Contents/Resources/claude-statusline-relay.sh"
chmod 755 "$app/Contents/Resources/claude-statusline-relay.sh"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 "${APP_SOURCES[@]}" \
  -o "$app/Contents/MacOS/TokenBar" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework CoreServices -framework Charts -framework UserNotifications -lsqlite3
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenBar</string>
<key>CFBundleIdentifier</key><string>local.star.CodexTokenBar</string>
<key>CFBundleName</key><string>Token Bar</string>
<key>CFBundleIconFile</key><string>TokenBar</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Token Bar contributors. MIT license.</string>
</dict></plist>
PLIST
if [[ -n "${APP_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
# Publish only a fully built and verified bundle; retain the old one until then.
if [ -e "$output" ]; then mv "$output" "$stage/previous.app"; fi
if ! mv "$app" "$output"; then
  if [ -e "$stage/previous.app" ]; then mv "$stage/previous.app" "$output"; fi
  exit 1
fi
printf '%s\n' "$output"
