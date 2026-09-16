#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv; export SUITES_FILE

out="$(sh scripts/matrix.sh amd64)"
assert_contains "$out" '"suite":"trixie"'          "trixie present"
assert_contains "$out" '"suite":"resolute"'        "resolute present"
assert_contains "$out" '"image":"ubuntu:26.04"'    "resolute image"
assert_contains "$out" '"arch":"amd64"'            "amd64 present"
assert_contains "$out" '"runner":"ubuntu-latest"'  "amd64 runner"
case "$out" in *arm64*) printf 'FAIL arm64 present when not requested\n'; FAILED=1;; *) printf 'ok   arm64 absent\n';; esac

out="$(sh scripts/matrix.sh amd64 arm64)"
assert_contains "$out" '"arch":"arm64"'                "arm64 present when asked"
assert_contains "$out" '"runner":"ubuntu-24.04-arm"'   "arm64 runner is the native one"

# Three suites in the fixture x two arches = six entries.
assert_eq "$(printf '%s' "$out" | tr ',' '\n' | grep -c '"suite"')" "6" "one entry per suite x arch"

exit "$FAILED"
