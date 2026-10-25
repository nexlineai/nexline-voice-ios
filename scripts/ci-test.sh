#!/usr/bin/env bash
# NexlineKit package tests (pure Swift, runs on the macOS host).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
set +e
swift test --package-path Packages/NexlineKit 2>&1 | tee build/swift-test.log
status=${PIPESTATUS[0]}
set -e
scripts/annotate-errors.sh build/swift-test.log
exit "$status"
