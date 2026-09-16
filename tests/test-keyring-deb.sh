#!/bin/sh
# usage: test-keyring-deb.sh <deb-dir> <codename>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh
# shellcheck source=/dev/null
. packaging/repo.conf

debdir="${1:?deb dir required}"
codename="${2:?codename required}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'skip (no dpkg-deb on this host)\n'
  exit 0
fi

deb="$(find "$debdir" -name "${KEYRING_PKG}_*_all.deb" -print -quit 2>/dev/null || true)"
if [ -z "$deb" ]; then printf 'FAIL no %s deb in %s\n' "$KEYRING_PKG" "$debdir"; exit 1; fi

files="$(dpkg-deb -c "$deb")"
ctrl="$(dpkg-deb -f "$deb")"
sources="$(dpkg-deb --fsys-tarfile "$deb" | tar -xO ./etc/apt/sources.list.d/"$SOURCES_FILE")"

assert_contains "$files" "/usr/share/keyrings/$KEYRING_FILE"     "ships the keyring"
assert_contains "$files" "/etc/apt/sources.list.d/$SOURCES_FILE" "ships the sources file"
assert_eq "$(printf '%s\n' "$ctrl" | awk '/^Architecture:/{print $2}')" "all" "architecture is all"

assert_contains "$sources" "Suites: $codename"  "sources names this suite"
assert_contains "$sources" "URIs: $REPO_URL"    "sources points at the repo"
assert_contains "$sources" "Signed-By: /usr/share/keyrings/$KEYRING_FILE" "sources is signed-by"

# The keyring must be a real binary OpenPGP keyring, not the armoured form:
# apt's Signed-By path does not accept armour in a .gpg file.
# Positive assertions: non-empty, valid, contains the right key.
dpkg-deb --fsys-tarfile "$deb" | tar -xO ./usr/share/keyrings/"$KEYRING_FILE" > /tmp/kr.gpg

# Assert non-empty
if [ ! -s /tmp/kr.gpg ]; then
  printf 'FAIL keyring is empty\n'; FAILED=1
else
  printf 'ok   keyring is non-empty\n'
fi

# Assert it's NOT ASCII-armoured (apt's Signed-By requires binary format)
if head -c 100 /tmp/kr.gpg | grep -q '^-----BEGIN PGP'; then
  printf 'FAIL keyring is ASCII-armoured; apt requires binary format\n'; FAILED=1
else
  printf 'ok   keyring is dearmoured\n'
fi

# Assert it's a valid OpenPGP keyring
if ! gpg --show-keys /tmp/kr.gpg >/dev/null 2>&1; then
  printf 'FAIL keyring is not a valid OpenPGP keyring\n'; FAILED=1
else
  printf 'ok   keyring is valid OpenPGP\n'
fi

# Assert it contains exactly the intended key
shipped_fp="$(gpg --with-colons --show-keys /tmp/kr.gpg 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
source_fp="$(gpg --with-colons --show-keys packaging/keys/unison-deb.asc 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
if [ "$shipped_fp" != "$source_fp" ]; then
  printf 'FAIL keyring fingerprint mismatch: shipped=%s source=%s\n' "$shipped_fp" "$source_fp"; FAILED=1
else
  printf 'ok   keyring contains the correct key\n'
fi

# conffile, so a local edit survives upgrades
assert_contains "$(dpkg-deb -I "$deb" conffiles 2>/dev/null || echo '')" \
  "/etc/apt/sources.list.d/$SOURCES_FILE" "sources file is a conffile"

exit "$FAILED"
