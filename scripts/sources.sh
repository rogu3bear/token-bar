#!/bin/bash
# Shared source discovery for build.sh and test.sh.
#
# Source location no longer determines build membership. Production files may
# live in any subdirectory of Sources/; targets name them and this file resolves
# the names. Two rules keep that safe:
#
#   1. The application links every discovered source minus APP_EXCLUDE, so a new
#      or unclassified file cannot silently leave the app.
#   2. Test groups name their members. An unknown or ambiguous name is a hard
#      error, so a renamed or deleted file fails loudly instead of vanishing.
#
# Written for bash 3.2, which is what macOS ships. No mapfile, no associative
# arrays.

SOURCE_ROOT="$PWD/Sources"

# Shipping bundle identity. build.sh writes it into Info.plist; package.sh
# reads that plist. DuplicateScan.identifier must match so Spotlight still
# finds every copy. Tests/SingleInstance/main.swift compares the two spellings.
BUNDLE_IDENTIFIER="local.star.CodexTokenBar"

# The single application entry point. It carries @main and therefore can never
# link into a test group, which uses Tests/<group>/main.swift as its entry.
APP_ENTRY="App.swift"

# Production sources deliberately excluded from the application build.
# Every entry needs a reason recorded beside it. Empty today: the application
# links all of Sources/.
APP_EXCLUDE=()

# Every production source, recursively, in deterministic order.
discover_sources() {
    find "$SOURCE_ROOT" -type f -name '*.swift' | LC_ALL=C sort
}

app_excluded() {
    local base="$1" skip
    for skip in ${APP_EXCLUDE+"${APP_EXCLUDE[@]}"}; do
        [ "$base" = "$skip" ] && return 0
    done
    return 1
}

# The application source set: everything discovered, minus explicit exclusions.
app_sources() {
    local path
    while IFS= read -r path; do
        app_excluded "$(basename "$path")" || printf '%s\n' "$path"
    done < <(discover_sources)
}

# Resolve bare file names to paths, wherever they now live. A name that matches
# nothing or more than one file is fatal, and the application entry point may
# never join a test group.
resolve_sources() {
    local name matches count
    for name in "$@"; do
        if [ "$name" = "$APP_ENTRY" ]; then
            echo "sources.sh: $APP_ENTRY carries @main and cannot link into a test group" >&2
            return 1
        fi
        matches=$(find "$SOURCE_ROOT" -type f -name "$name" | LC_ALL=C sort)
        count=$(printf '%s\n' "$matches" | grep -c '[^[:space:]]' || true)
        if [ "$count" -eq 0 ]; then
            echo "sources.sh: no source named '$name' under Sources/" >&2
            return 1
        fi
        if [ "$count" -gt 1 ]; then
            echo "sources.sh: '$name' is ambiguous:" >&2
            printf '  %s\n' $matches >&2
            return 1
        fi
        printf '%s\n' "$matches"
    done
}

# Read a newline-separated list into a named array. bash 3.2 has no mapfile.
read_into() {
    local __name="$1"
    eval "$__name=()"
    local __line
    while IFS= read -r __line; do
        [ -n "$__line" ] || continue
        eval "$__name+=(\"\$__line\")"
    done
}

# Token Bar's SwiftUI sources need Xcode's toolchain. An unaccepted Xcode license
# stops xcrun entirely, and Command Line Tools lack the SwiftUI macro plugin, so
# state the remedy before compiling instead of after a page of compiler errors.
require_swift_toolchain() {
    local report
    if ! report=$(xcrun swiftc --version 2>&1); then
        printf '%s\n' "$report" >&2
        case "$report" in
            *license*) echo 'Swift toolchain blocked: accept the Xcode license in Terminal with: sudo xcodebuild -license accept' >&2 ;;
            *) echo 'Swift toolchain unavailable: install Xcode and select it with xcode-select.' >&2 ;;
        esac
        return 1
    fi
    case "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}" in
        *CommandLineTools*) echo 'Swift toolchain warning: Command Line Tools cannot expand the SwiftUI macros these sources use; select Xcode if compilation fails.' >&2 ;;
    esac
}
