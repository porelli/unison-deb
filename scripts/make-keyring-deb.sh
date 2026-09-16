#!/bin/sh
# Build the unison-deb-keyring package for one suite.
# usage: make-keyring-deb.sh <codename> <pubkey.asc> <outdir>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=packaging/repo.conf
. packaging/repo.conf

codename="${1:?codename required}"
pubkey="${2:?armoured public key required}"
outdir="${3:?output directory required}"
krev="$(cat packaging/keyring-revision)"
version="$(keyring_version "$krev" "$codename")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/DEBIAN" \
         "$work/usr/share/keyrings" \
         "$work/etc/apt/sources.list.d"

# apt's Signed-By requires a binary keyring, not armour.
gpg --dearmor < "$pubkey" > "$work/usr/share/keyrings/$KEYRING_FILE"

cat > "$work/etc/apt/sources.list.d/$SOURCES_FILE" <<EOF
Types: deb
URIs: $REPO_URL
Suites: $codename
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/$KEYRING_FILE
EOF

cat > "$work/DEBIAN/conffiles" <<EOF
/etc/apt/sources.list.d/$SOURCES_FILE
EOF

cat > "$work/DEBIAN/control" <<EOF
Package: $KEYRING_PKG
Version: $version
Architecture: all
Maintainer: $MAINTAINER
Section: misc
Priority: optional
Description: apt configuration for the $REPO_NAME repository
 Installs the signing key and apt source entry for $REPO_URL , which
 carries the current upstream release of Unison including unison-fsmonitor
 for $codename.
 .
 Fetch this package directly and install it with dpkg; it is what configures
 the repository that apt would otherwise need in order to find it.
EOF

mkdir -p "$outdir"
dpkg-deb --root-owner-group --build "$work" \
  "$outdir/${KEYRING_PKG}_${version}_all.deb"

sh tests/test-keyring-deb.sh "$outdir" "$codename"
