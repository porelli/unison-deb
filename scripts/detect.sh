#!/bin/sh
# Decide whether there is a new version worth building.
# usage: detect.sh [--state <file>] [--force] [--version <v>]
# Prints key=value lines: upstream, target, changed
#
# Set UNISON_RELEASE_JSON to a file path to read the release feed from disk
# instead of the network (used by the tests).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=packaging/repo.conf
. packaging/repo.conf

state=""; force=0; version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state)   state="${2:?}"; shift 2 ;;
    --force)   force=1; shift ;;
    --version) version="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

pkgrev="$(cat packaging/revision)"

if [ -z "$version" ]; then
  if [ -n "${UNISON_RELEASE_JSON:-}" ]; then
    feed="$(cat "$UNISON_RELEASE_JSON")"
  else
    # The 'latest' endpoint excludes prereleases by definition, which is the
    # only thing keeping release candidates out of the repository.
    feed="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest")"
  fi
  version="$(printf '%s' "$feed" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    | head -1)"
fi

[ -n "$version" ] || { echo "could not determine upstream version" >&2; exit 1; }

target="$version+porelli$pkgrev"

published=""
if [ -n "$state" ] && [ -f "$state" ]; then
  published="$(sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$state" | head -1)"
fi

if [ "$force" -eq 1 ] || [ "$target" != "$published" ]; then
  changed=true
else
  changed=false
fi

echo "upstream=$version"
echo "target=$target"
echo "changed=$changed"
