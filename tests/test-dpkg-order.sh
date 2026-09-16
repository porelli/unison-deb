#!/bin/sh
# Verifies the version scheme sorts as the spec claims. Requires dpkg, so it
# skips on machines without it (macOS) and runs in CI containers.
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh

if ! command -v dpkg >/dev/null 2>&1; then
  printf 'skip (no dpkg on this host)\n'
  exit 0
fi

gt() {
  if dpkg --compare-versions "$1" gt "$2"; then
    printf 'ok   %s > %s\n' "$1" "$2"
  else
    printf 'FAIL %s is not > %s\n' "$1" "$2"; FAILED=1
  fi
}

# Beats the distro packages we are replacing (versions checked 2026-09-16).
gt '2.54.0-1+porelli1~deb13'  '2.53+1-1'
gt '2.54.0-1+porelli1~ub2604' '2.53+1build1'

# Beats a hypothetical future distro release of the same upstream version.
# This is the property the "+porelli1" exists for; without it these would tie.
gt '2.54.0-1+porelli1~deb13'  '2.54.0-1'
gt '2.54.0-1+porelli1~ub2604' '2.54.0-1'

# Orders across a dist-upgrade.
gt '2.54.0-1+porelli1~deb14'  '2.54.0-1+porelli1~deb13'
gt '2.54.0-1+porelli1~ub2804' '2.54.0-1+porelli1~ub2604'

# A newer upstream beats an older one, and a packaging bump beats no bump.
gt '2.55.0-1+porelli1~deb13'  '2.54.0-1+porelli1~deb13'
gt '2.54.0-1+porelli2~deb13'  '2.54.0-1+porelli1~deb13'

exit "$FAILED"
