#!/bin/sh
# Asserts what the built packages must contain.
# usage: test-deb-contents.sh <deb-dir> <expected-version>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh

debdir="${1:?usage: test-deb-contents.sh <deb-dir> <expected-version>}"
want_version="${2:?expected version required}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'skip (no dpkg-deb on this host)\n'
  exit 0
fi

# shellcheck disable=SC2012
unison_deb="$(ls "$debdir"/unison_*.deb 2>/dev/null | head -1 || true)"
# shellcheck disable=SC2012
gtk_deb="$(ls "$debdir"/unison-gtk_*.deb 2>/dev/null | head -1 || true)"

if [ -z "$unison_deb" ]; then printf 'FAIL no unison_*.deb in %s\n' "$debdir"; exit 1; fi
if [ -z "$gtk_deb" ];    then printf 'FAIL no unison-gtk_*.deb in %s\n' "$debdir"; exit 1; fi

u_files="$(dpkg-deb -c "$unison_deb")"
g_files="$(dpkg-deb -c "$gtk_deb")"
u_ctrl="$(dpkg-deb -f "$unison_deb")"
g_ctrl="$(dpkg-deb -f "$gtk_deb")"

# The entire point of the project. Match whole paths to avoid false positives
# (e.g. "./usr/bin/unison" matching "./usr/bin/unison-fsmonitor").
# dpkg-deb -c output: for files, line ends with path; for symlinks, path is followed by " -> target"
if ! printf '%s\n' "$u_files" | grep -q ' \./usr/bin/unison-fsmonitor\( \|$\)'; then
  printf 'FAIL unison does not ship unison-fsmonitor\n'; FAILED=1
else
  printf 'ok   unison ships unison-fsmonitor\n'
fi
if ! printf '%s\n' "$u_files" | grep -q ' \./usr/bin/unison\( \|$\)'; then
  printf 'FAIL unison does not ship unison\n'; FAILED=1
else
  printf 'ok   unison ships unison\n'
fi
assert_contains "$u_files" "./usr/share/man/man1/unison.1" "unison ships its man page"
assert_contains "$u_files" "unison-manual.txt"          "unison ships the text manual"

assert_eq "$(printf '%s\n' "$u_ctrl" | awk '/^Version:/{print $2}')" \
          "$want_version" "unison version field"
assert_contains "$u_ctrl" "Provides: unison-fsmonitor" "unison provides unison-fsmonitor"

# A GTK dependency on the CLI package would drag X onto headless servers.
u_deps="$(printf '%s\n' "$u_ctrl" | awk '/^Depends:/{ $1=""; print }')"
case "$u_deps" in
  *gtk*|*libx11*|*libcairo*|*libpango*)
    printf 'FAIL unison depends on GUI libraries: %s\n' "$u_deps"; FAILED=1 ;;
  *) printf 'ok   unison has no GUI dependencies\n' ;;
esac

# Match whole paths for the binaries to avoid false substring matches
# For symlinks, dpkg -c shows "path -> target", so we can't use $
if ! printf '%s\n' "$g_files" | grep -q ' \./usr/bin/unison-gui\( \|$\)'; then
  printf 'FAIL unison-gtk does not ship unison-gui\n'; FAILED=1
else
  printf 'ok   unison-gtk ships unison-gui\n'
fi
if ! printf '%s\n' "$g_files" | grep -q ' \./usr/bin/unison-gtk\( \|$\)'; then
  printf 'FAIL unison-gtk does not ship the compat symlink\n'; FAILED=1
else
  printf 'ok   unison-gtk ships the compat symlink\n'
fi
assert_contains "$g_files" "unison-gui.desktop"   "unison-gtk ships the desktop entry"
assert_contains "$g_files" "icons/hicolor"        "unison-gtk ships icons"
assert_eq "$(printf '%s\n' "$g_ctrl" | awk '/^Version:/{print $2}')" \
          "$want_version" "unison-gtk version field"
assert_contains "$g_ctrl" "unison (= $want_version)" "unison-gtk pins unison to the same version"

exit "$FAILED"
