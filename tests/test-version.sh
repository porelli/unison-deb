#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv
export SUITES_FILE
. scripts/lib.sh

assert_eq "$(suite_vendor trixie)"   "debian"        "vendor of trixie"
assert_eq "$(suite_image trixie)"    "debian:trixie" "image of trixie"
assert_eq "$(suite_vtag trixie)"     "deb13"         "vtag of trixie"
assert_eq "$(suite_vendor resolute)" "ubuntu"        "vendor of resolute"
assert_eq "$(suite_image resolute)"  "ubuntu:26.04"  "image of resolute"
assert_eq "$(suite_vtag resolute)"   "ub2604"        "vtag of resolute"

assert_eq "$(suite_list | tr '\n' ' ')" "trixie resolute forky " "suite_list order"

assert_eq "$(deb_version 2.54.0 1 trixie)"   "2.54.0-1+porelli1~deb13"  "trixie version"
assert_eq "$(deb_version 2.54.0 1 resolute)" "2.54.0-1+porelli1~ub2604" "resolute version"
assert_eq "$(deb_version 2.55.1 3 forky)"    "2.55.1-1+porelli3~deb14"  "revision is substituted"

assert_eq "$(keyring_version 1 trixie)"   "1~deb13"  "keyring version trixie"
assert_eq "$(keyring_version 2 resolute)" "2~ub2604" "keyring version resolute"

# An unknown suite must fail loudly rather than emit a malformed version.
assert_fails suite_vtag bookworm
assert_fails deb_version 2.54.0 1 bookworm

# Test the deb-version.sh wrapper with real packaging/revision (value 2)
assert_eq "$(sh scripts/deb-version.sh 2.54.0 trixie)"   "2.54.0-1+porelli2~deb13"  "deb-version.sh trixie"
assert_eq "$(sh scripts/deb-version.sh 2.54.0 resolute)" "2.54.0-1+porelli2~ub2604" "deb-version.sh resolute"
assert_fails sh scripts/deb-version.sh 2.54.0 bookworm

# Verify that unknown suite produces stderr output (not just a silent failure)
_stderr="$(sh scripts/deb-version.sh 2.54.0 bookworm 2>&1 >/dev/null || true)"
if [ -n "$_stderr" ]; then
  printf 'ok   deb-version.sh writes stderr on unknown suite\n'
else
  printf 'FAIL deb-version.sh should write stderr on unknown suite\n'
  FAILED=1
fi

exit "$FAILED"
