#!/bin/sh
# Wrapper for deb_version so CI never has to splice shell quoting.
# Usage: deb-version.sh <upstream> <codename>
# Reads packaging/revision, prints the full Debian version to stdout.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh

if [ $# -ne 2 ]; then
  printf 'usage: %s <upstream> <codename>\n' "$0" >&2
  exit 1
fi

PKGREV="$(cat packaging/revision)"
if ! deb_version "$1" "$PKGREV" "$2"; then
  printf 'error: unknown suite: %s\n' "$2" >&2
  exit 1
fi
