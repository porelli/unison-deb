#!/bin/sh
# Print the newest retained version for a suite that is NOT the current one,
# or an empty string if there is none. Used to test retention.
# usage: previous-version.sh <repo-dir> <codename> <current-version>
set -eu
repo="${1:?repo dir required}"
codename="${2:?codename required}"
current="${3:?current version required}"

dir="$repo/pool/$codename/main/u/unison"
[ -d "$dir" ] || { echo ""; exit 0; }

# shellcheck disable=SC2012
ls "$dir" 2>/dev/null \
  | sed -n 's/^unison_\(.*\)_[a-z0-9]*\.deb$/\1/p' \
  | grep -vFx "$current" \
  | sort -Vr \
  | head -1
