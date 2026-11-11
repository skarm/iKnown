#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/iknow-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 6 -module-cache-path "$check_dir/ModuleCache" \
    iKnow/Demo/*.swift iKnow/Graph/*.swift iKnow/Reports/*.swift iKnow/Storage/*.swift \
    Tests/ReportChecks.swift -o "$check_dir/check"
"$check_dir/check" "$check_dir/snapshot"
