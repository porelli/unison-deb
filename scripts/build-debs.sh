#!/bin/sh
# Build unison and unison-gtk for one suite. Runs INSIDE a container of that
# suite -- it installs build dependencies, so do not run it on your laptop.
#
# usage: build-debs.sh <upstream> <codename> <outdir>
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck disable=SC1091
. packaging/repo.conf

upstream="${1:?upstream version required}"
codename="${2:?codename required}"
outdir="${3:?output directory required}"
pkgrev="$(cat packaging/revision)"
version="$(deb_version "$upstream" "$pkgrev" "$codename")"

echo "==> building unison $version for $codename on $(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl dpkg-dev build-essential lintian

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> fetching upstream source"
curl -fsSL "https://github.com/$UPSTREAM_REPO/archive/refs/tags/v$upstream.tar.gz" \
  -o "$work/src.tar.gz"
tar -xzf "$work/src.tar.gz" -C "$work"
src="$work/unison-$upstream"
test -d "$src" || { echo "unexpected tarball layout in $work" >&2; exit 1; }

echo "==> installing packaging"
cp -a packaging/debian "$src/debian"
sh scripts/changelog.sh "$upstream" "$pkgrev" "$codename" "$src/debian/changelog"

echo "==> installing build dependencies from debian/control"
( cd "$src" && apt-get build-dep -y ./ )

echo "==> building"
( cd "$src" && dpkg-buildpackage -b -uc -us )

echo "==> build gates"
"$src/src/unison" -version
"$src/src/unison-fsmonitor" -version
ldd -r "$src/src/unison-gui" > "$work/ldd.txt" 2>&1 || true
if grep -qE 'not found|undefined symbol' "$work/ldd.txt"; then
  echo "unison-gui has unresolved dynamic linkage:" >&2
  cat "$work/ldd.txt" >&2
  exit 1
fi
"$src/src/unison-gui" -version

mkdir -p "$outdir"
cp "$work"/*.deb "$outdir"/
ls -l "$outdir"

echo "==> lintian (advisory)"
lintian "$work"/*.deb || echo "lintian reported issues (advisory, not fatal)"

echo "==> asserting package contents"
sh "$root/tests/test-deb-contents.sh" "$outdir" "$version"
