#!/bin/sh
# Runs all argument-free unit tests, reports a summary, exits non-zero if any failed.
# Tests needing dpkg are skipped unless dpkg is present.
set -eu
cd "$(dirname "$0")/.."

# EXPLICIT list of unit tests that take no arguments.
# New argument-free tests must be added to this list.
# Do NOT glob test-*.sh — some tests require arguments and will abort.
TESTS="
  tests/test-version.sh
  tests/test-dpkg-order.sh
  tests/test-detect.sh
  tests/test-publish.sh
"

rc=0
for t in $TESTS; do
  printf '\n=== %s ===\n' "$t"
  if sh "$t"; then :; else rc=1; fi
done
if [ "$rc" -eq 0 ]; then printf '\nall tests passed\n'; else printf '\nTESTS FAILED\n'; fi
exit "$rc"
