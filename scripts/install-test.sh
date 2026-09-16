#!/bin/sh
# Install from a locally served copy of the repository and prove it works.
# Runs INSIDE a container of the target suite; it modifies apt configuration.
#
# usage: install-test.sh <repo-dir> <codename> <expected-version> [previous-version]
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=/dev/null
. packaging/repo.conf

repo="${1:?repo dir required}"
codename="${2:?codename required}"
want="${3:?expected version required}"
previous="${4:-}"
repo="$(cd "$repo" && pwd)"

# TEMPORARY: Force failure to prove C1 gating works
echo "PROOF: deliberately failing to test C1 gate" >&2
exit 1

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 ca-certificates

echo "==> serving the repository on 127.0.0.1:8000"
( cd "$repo" && python3 -m http.server 8000 --bind 127.0.0.1 >/tmp/http.log 2>&1 ) &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT

# Wait for the server rather than sleeping a guess.
i=0
while [ "$i" -lt 50 ]; do
  if python3 -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1",8000))==0 else 1)'; then break; fi
  i=$((i+1)); sleep 0.2
done
[ "$i" -lt 50 ] || { echo "http server never came up" >&2; cat /tmp/http.log >&2; exit 1; }

echo "==> installing the keyring package"
krev="$(cat packaging/keyring-revision)"
kver="$(keyring_version "$krev" "$codename")"
dpkg -i "$repo/bootstrap/$codename/${KEYRING_PKG}_${kver}_all.deb"

# Point the installed sources file at the local server instead of Pages, which
# is the only thing that differs from a real client.
sed -i "s|URIs: .*|URIs: http://127.0.0.1:8000|" \
  "/etc/apt/sources.list.d/$SOURCES_FILE"
cat "/etc/apt/sources.list.d/$SOURCES_FILE"

echo "==> apt update (this is where a bad signature or index shows up)"
apt-get update

echo "==> our repository must outrank the distro's"
apt-cache policy unison
cand="$(apt-cache policy unison | awk '/Candidate:/{print $2}')"
if [ "$cand" != "$want" ]; then
  echo "FAIL candidate is $cand, expected $want" >&2
  exit 1
fi
echo "ok   candidate is $want"

echo "==> unison must install without pulling in GTK"
apt-get install -y unison
inst="$(dpkg-query -W -f='${Package}\n' | sort)"
# Aligned with test-deb-contents.sh to catch gtk, libx11, libcairo, libpango, and gdk-pixbuf
if printf '%s\n' "$inst" | grep -qiE 'gtk|libx11|libcairo|libpango|gdk-pixbuf'; then
  echo "FAIL installing unison alone pulled in GUI libraries:" >&2
  printf '%s\n' "$inst" | grep -iE 'gtk|libx11|libcairo|libpango|gdk-pixbuf' >&2
  exit 1
fi
echo "ok   no GUI libraries pulled in"

echo "==> the binary this project exists for"
test -x /usr/bin/unison-fsmonitor || { echo "FAIL no /usr/bin/unison-fsmonitor" >&2; exit 1; }
/usr/bin/unison-fsmonitor -version
/usr/bin/unison -version
got="$(dpkg-query -W -f='${Version}' unison)"
[ "$got" = "$want" ] || { echo "FAIL installed $got, expected $want" >&2; exit 1; }
echo "ok   installed version is $want"

echo "==> the GUI package installs too"
apt-get install -y unison-gtk
test -x /usr/bin/unison-gui || { echo "FAIL no /usr/bin/unison-gui" >&2; exit 1; }
test -L /usr/bin/unison-gtk || { echo "FAIL /usr/bin/unison-gtk is not a symlink" >&2; exit 1; }
echo "ok   GUI installed with its compat symlink"

echo "==> retained older versions must remain installable"
if [ -n "$previous" ]; then
  apt-cache madison unison
  if ! apt-cache madison unison | grep -q "$previous"; then
    echo "FAIL $previous is not in the index -- was --multiversion dropped?" >&2
    exit 1
  fi
  apt-get install -y --allow-downgrades "unison=$previous"
  got="$(dpkg-query -W -f='${Version}' unison)"
  [ "$got" = "$previous" ] || { echo "FAIL downgrade landed on $got" >&2; exit 1; }
  echo "ok   $previous is installable"
  apt-get install -y --allow-downgrades "unison=$want"
else
  echo "skip retention check (no previous version yet)"
fi

echo "==> the actual point: a real sync driven by fsmonitor"
rm -rf /tmp/synca /tmp/syncb /tmp/unison-state
mkdir -p /tmp/synca /tmp/syncb /tmp/unison-state
export UNISON=/tmp/unison-state
echo original > /tmp/synca/first.txt

unison /tmp/synca /tmp/syncb -ui text -batch -auto -repeat watch \
  > /tmp/unison-watch.log 2>&1 &
uni_pid=$!
# shellcheck disable=SC2064
trap "kill $uni_pid 2>/dev/null || true; kill $http_pid 2>/dev/null || true" EXIT

wait_for() {
  _f="$1"; _n=0
  while [ "$_n" -lt 60 ]; do
    [ -f "$_f" ] && return 0
    _n=$((_n+1)); sleep 0.5
  done
  return 1
}

if ! wait_for /tmp/syncb/first.txt; then
  echo "FAIL initial sync never happened" >&2
  cat /tmp/unison-watch.log >&2
  exit 1
fi
echo "ok   initial sync propagated"

# The real test: a change made AFTER unison started must propagate without any
# further invocation. Only the file watcher can do that.
echo added-later > /tmp/synca/second.txt
if ! wait_for /tmp/syncb/second.txt; then
  echo "FAIL a change made while watching did not propagate -- fsmonitor is not working" >&2
  cat /tmp/unison-watch.log >&2
  exit 1
fi
body="$(cat /tmp/syncb/second.txt)"
[ "$body" = "added-later" ] || { echo "FAIL propagated wrong content" >&2; exit 1; }
echo "ok   a live change propagated -- fsmonitor works"

kill "$uni_pid" 2>/dev/null || true
echo "ALL INSTALL TESTS PASSED for $codename"
