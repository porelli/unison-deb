#!/bin/sh
# Prove that --multiversion makes dpkg-scanpackages index all versions, not just the newest.
# usage: test-multiversion.sh <path-to-any-deb>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh

deb="${1:?path to a .deb file required}"
[ -f "$deb" ] || { echo "not a file: $deb" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pool="$tmpdir/pool/suite/main/u/pkg"
mkdir -p "$pool"

# Extract the original deb to get its control file
extractdir="$tmpdir/extract"
dpkg-deb -R "$deb" "$extractdir"

# Read the original version
origver="$(awk '/^Version:/ {print $2}' "$extractdir/DEBIAN/control")"
[ -n "$origver" ] || { echo "could not read Version from control" >&2; exit 1; }

# Copy the original deb into the pool
cp "$deb" "$pool/"

# Synthesise a higher version by bumping the control file
# We use a simple suffix to ensure it sorts higher
newver="${origver}.99"
awk -v nv="$newver" '/^Version:/ {print "Version: " nv; next} {print}' \
  "$extractdir/DEBIAN/control" > "$extractdir/DEBIAN/control.new"
mv "$extractdir/DEBIAN/control.new" "$extractdir/DEBIAN/control"

# Rebuild as a second .deb
newdeb="$pool/fake_${newver}_amd64.deb"
dpkg-deb -b "$extractdir" "$newdeb" >/dev/null 2>&1

# Now we have two versions in the pool. Scan WITH --multiversion.
pkglist_multi="$(cd "$tmpdir" && dpkg-scanpackages --multiversion --arch amd64 pool/suite 2>/dev/null | grep '^Version:' | awk '{print $2}' | sort)"

# Scan WITHOUT --multiversion.
pkglist_single="$(cd "$tmpdir" && dpkg-scanpackages --arch amd64 pool/suite 2>/dev/null | grep '^Version:' | awk '{print $2}' | sort)"

# Assert the WITH case indexes both
case "$pkglist_multi" in
  *"$origver"*) printf 'ok   --multiversion indexes original version %s\n' "$origver" ;;
  *) printf 'FAIL --multiversion missing original version %s\n' "$origver"; FAILED=1 ;;
esac

case "$pkglist_multi" in
  *"$newver"*) printf 'ok   --multiversion indexes synthesised version %s\n' "$newver" ;;
  *) printf 'FAIL --multiversion missing synthesised version %s\n' "$newver"; FAILED=1 ;;
esac

# Assert the WITHOUT case indexes only one
linecount="$(printf '%s\n' "$pkglist_single" | grep -c .)"
assert_eq "$linecount" 1 "without --multiversion indexes exactly 1 version"

# Assert it picked the highest
case "$pkglist_single" in
  *"$newver"*) printf 'ok   without --multiversion picked the highest version %s\n' "$newver" ;;
  *) printf 'FAIL without --multiversion did not pick %s\n' "$newver"; FAILED=1 ;;
esac

exit "$FAILED"
