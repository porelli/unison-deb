#!/bin/sh
# Emit the build matrix as one line of JSON.
# usage: matrix.sh <arch> [arch...]
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

[ $# -gt 0 ] || { echo "at least one architecture required" >&2; exit 2; }

runner_for() {
  case "$1" in
    amd64) echo "ubuntu-latest" ;;
    arm64) echo "ubuntu-24.04-arm" ;;
    *) echo "no runner known for architecture $1" >&2; return 1 ;;
  esac
}

printf '{"include":['
first=1
for suite in $(suite_list); do
  image="$(suite_image "$suite")"
  for arch in "$@"; do
    runner="$(runner_for "$arch")"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"suite":"%s","image":"%s","arch":"%s","runner":"%s"}' \
      "$suite" "$image" "$arch" "$runner"
  done
done
printf ']}\n'
