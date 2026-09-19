#!/bin/sh
# Emit the landing page served at the repository root.
# usage: make-index.sh <repo-dir>
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=/dev/null
. packaging/repo.conf
repo="${1:?repo dir required}"

version="$(sed -n 's/.*"upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/state.json" | head -1)"

cat <<EOF
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>$REPO_NAME</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
  pre { background: #f4f4f5; padding: 1rem; overflow-x: auto; border-radius: 6px; }
  code { font-family: ui-monospace, monospace; }
</style>
<h1>$REPO_NAME</h1>
<p>An apt repository carrying Unison <strong>$version</strong> — including
<code>unison-fsmonitor</code>, which the Debian and Ubuntu packages omit, so
<code>unison -repeat watch</code> works.</p>
<p>Suites: $(suite_list | tr '\n' ' '). Architectures: amd64, arm64.</p>
<h2>Install</h2>
<pre><code>. /etc/os-release
curl -fsSLO https://github.com/porelli/unison-deb/releases/latest/download/unison-deb-keyring-\$VERSION_CODENAME.deb
sudo dpkg -i unison-deb-keyring-\$VERSION_CODENAME.deb
sudo apt update && sudo apt install unison unison-gtk</code></pre>
<p>Unison requires the <em>same version at both ends</em> of a synchronization,
so add this repository on every host you sync between.</p>
<p><a href="unison-deb.asc">Signing key</a> · <a href="state.json">state.json</a></p>
</html>
EOF
