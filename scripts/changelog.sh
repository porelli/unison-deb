#!/bin/sh
# Generate a debian/changelog for one suite.
# usage: changelog.sh <upstream> <pkgrev> <codename> <outfile>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck disable=SC1091
. packaging/repo.conf

upstream="${1:?upstream version required}"
pkgrev="${2:?packaging revision required}"
codename="${3:?codename required}"
out="${4:?output file required}"

version="$(deb_version "$upstream" "$pkgrev" "$codename")"

# Reproducible when SOURCE_DATE_EPOCH is set (dpkg sets it from the changelog,
# so seed it from the environment where available).
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  stamp="$(date -u -R -d "@$SOURCE_DATE_EPOCH" 2>/dev/null || date -R)"
else
  stamp="$(date -R)"
fi

cat > "$out" <<EOF
unison ($version) $codename; urgency=medium

  * Automated build of upstream $upstream for $codename.
  * Includes unison-fsmonitor, which the distribution's package omits.

 -- $MAINTAINER  $stamp
EOF
