#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/sources.sh
mkdir -p build/tests

# Optional single-group run: ./scripts/test.sh cost
ONLY="${1:-}"
RAN=0

# Group membership is declared once, by file name. scripts/sources.sh resolves
# each name wherever the file now lives, so moving a source between directories
# never edits this file, and a missing or ambiguous name fails the run.

# The ledger, cost and provider surfaces that every logic group links.
CORE="ProviderUsage.swift UsageComparison.swift CostRateHistory.swift CostCoverage.swift RequestExport.swift
      CoverageAudit.swift UsageMetadata.swift RequestArchive.swift LiveStateStore.swift CostPricing.swift
      CostReport.swift CostRecovery.swift UsageInsights.swift Appearance.swift PageStyle.swift
      Usage.swift UsageStore.swift ImportProgress.swift GrokUsage.swift Activity.swift LiveTool.swift ClaudeActivityReader.swift ActivityFeed.swift EventIndex.swift
      PlanHistory.swift TaskCatalog.swift Reports.swift ReportEngine.swift ReportIndexStorage.swift PrivateCache.swift UsageTimeline.swift LiveMonitor.swift ClaudeQuotaMonitor.swift ClaudeStatuslineConnection.swift
      Project.swift DimensionReport.swift TokenConvention.swift Integrity.swift
      ClaudeCodeUsage.swift OpenCodeUsage.swift ForeignHarnessScan.swift IncrementalScan.swift HarnessDiscovery.swift
      Tachometer.swift SignInTimeline.swift CodexInstallation.swift GrokInstallation.swift GrokQuotaMonitor.swift"

GUARD="QuotaGuardEvaluation.swift QuotaGuardCoordinator.swift QuotaGuardNotifications.swift QuotaGuardViews.swift"
MENU="MenuBarDial.swift MenuBarSettings.swift FirstRunWelcome.swift ClaudeConnectionControl.swift"

# build_group <executable> <test entry> <extra swiftc flags> <source names...>
build_group() {
    local exe="$1" entry="$2" flags="$3"
    shift 3
    if [ -n "$ONLY" ] && [ "$ONLY" != "$exe" ]; then return 0; fi
    RAN=$((RAN + 1))
    if [ ! -f "$entry" ]; then
        echo "test.sh: missing test entry point $entry" >&2
        return 1
    fi
    local resolved files
    if ! resolved=$(resolve_sources "$@"); then
        echo "test.sh: group '$exe' has unresolvable membership; refusing to compile a partial set" >&2
        return 1
    fi
    read_into files <<<"$resolved"
    printf '==> %s (%s sources)\n' "$exe" "${#files[@]}"
    xcrun swiftc $flags "${files[@]}" "$entry" -o "build/tests/$exe"
    "build/tests/$exe"
}

build_group usage      Tests/main.swift            "-swift-version 5 -lsqlite3" $CORE
build_group menu-bar   Tests/MenuBar/main.swift    "-swift-version 5 -lsqlite3" $CORE $MENU $GUARD
build_group quota-guard Tests/QuotaGuard/main.swift "-swift-version 5 -lsqlite3" $CORE $MENU $GUARD
build_group hover      Tests/Hover/main.swift      ""                           ContainedHover.swift
build_group insights   Tests/Insights/main.swift   "-lsqlite3"                  Insights.swift PromptIndex.swift PrivateCache.swift PromptReadState.swift InsightsModel.swift
build_group feedback   Tests/Feedback/main.swift   ""                           Feedback.swift CodexInstallation.swift
build_group appearance Tests/Appearance/main.swift "-swift-version 5 -lsqlite3" $CORE FirstRunWelcome.swift PreviewFixture.swift UsageMetric.swift UsageTimelineChart.swift TokenFormatting.swift
build_group cost       Tests/Cost/main.swift       "-swift-version 5 -lsqlite3" $CORE
build_group accuracy   Tests/Accuracy/main.swift   "-swift-version 5 -lsqlite3" $CORE
build_group grok       Tests/Grok/main.swift       "-swift-version 5 -lsqlite3" $CORE
build_group dimensions Tests/Dimensions/main.swift "-swift-version 5 -lsqlite3" $CORE
build_group harnesses  Tests/Harnesses/main.swift  "-swift-version 5 -lsqlite3" $CORE LogStream.swift
build_group integrity  Tests/Integrity/main.swift  "-swift-version 5 -lsqlite3" $CORE Provenance.swift ProvenanceViews.swift

# The single-instance group needs the path of its own source, because it
# compiles a second process to prove the lock refuses one.
if [ -z "$ONLY" ] || [ "$ONLY" = "single-instance" ]; then
    RAN=$((RAN + 1))
    SI=$(resolve_sources SingleInstance.swift)
    printf '==> %s (1 sources)\n' single-instance
    xcrun swiftc -swift-version 5 "$SI" Tests/SingleInstance/main.swift -o build/tests/single-instance
    build/tests/single-instance "$SI"
    python3 Tests/SingleInstance/installer.py
    python3 Tests/SingleInstance/release.py
fi

if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
    echo "test.sh: no group named '$ONLY'" >&2
    exit 1
fi
