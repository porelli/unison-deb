#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv; export SUITES_FILE
UNISON_RELEASE_JSON=tests/fixtures/release-2.54.0.json; export UNISON_RELEASE_JSON

get() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{print $2}'; }

# No state at all: everything is new.
out="$(sh scripts/detect.sh --state /nonexistent)"
assert_eq "$(get "$out" upstream)" "2.54.0"          "upstream parsed from tag_name"
assert_eq "$(get "$out" target)"   "2.54.0+porelli1" "target includes the packaging revision"
assert_eq "$(get "$out" changed)"  "true"            "no state means changed"

# State matching the target: nothing to do.
out="$(sh scripts/detect.sh --state tests/fixtures/state-2.54.0.json)"
assert_eq "$(get "$out" changed)" "false" "matching state means unchanged"

# --force overrides an identical state.
out="$(sh scripts/detect.sh --state tests/fixtures/state-2.54.0.json --force)"
assert_eq "$(get "$out" changed)" "true" "force overrides"

# An explicit version wins over the release feed.
out="$(sh scripts/detect.sh --state /nonexistent --version 2.55.1)"
assert_eq "$(get "$out" upstream)" "2.55.1" "explicit version wins"
assert_eq "$(get "$out" changed)"  "true"   "explicit new version is changed"

exit "$FAILED"
