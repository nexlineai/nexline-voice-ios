#!/usr/bin/env bash
# Turns errors in an xcodebuild / swift log into GitHub annotations. On a public repo annotations can be
# read without a token (check-runs API); the raw logs can't, so this is how a failed build is diagnosed.
# GitHub keeps at most 10 error annotations per step.
set -uo pipefail
log="$1"
root="${GITHUB_WORKSPACE:-$PWD}"
[ -f "$log" ] || exit 0
esc() { sed -e 's/%/%25/g'; }
{
  # file:line[:col]: error: message
  sed -nE "s#^${root}/([^:]+):([0-9]+):([0-9]+:)? *error: (.*)#::error file=\1,line=\2::\4#p" "$log"
  # errors without a file (signing, export, xcodebuild itself)
  grep -E '^(xcodebuild: )?error: |^error: exportArchive' "$log" | sed -E 's#^#::error::#'
} | esc | awk '!seen[$0]++' | head -n 10
exit 0
