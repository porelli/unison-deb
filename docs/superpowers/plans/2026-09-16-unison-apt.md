# unison-apt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An apt repository, published by CI to GitHub Pages, carrying the current upstream release of Unison — including the `unison-fsmonitor` binary the distro packages omit — for Debian trixie and Ubuntu 26.04 on amd64 and arm64.

**Architecture:** A single workflow detects new upstream releases, builds Debian packages inside a container of each target suite (so dependencies are derived, not guessed), assembles a signed apt repository with `dpkg-scanpackages` and `apt-ftparchive`, proves it works by installing from it in a fresh container and running a real `-repeat watch` sync, then publishes it as a single-commit orphan branch that Pages serves directly. Every stage is a standalone POSIX shell script the workflow calls, so the same logic runs on Gitea, on GitHub, and by hand.

**Tech Stack:** POSIX shell, debhelper 13, `dpkg-buildpackage`, `dpkg-scanpackages`, `apt-ftparchive`, GnuPG, GitHub Actions / Gitea Actions, Docker containers (`debian:trixie`, `ubuntu:26.04`), OCaml (from each suite).

**Spec:** `docs/superpowers/specs/2026-09-16-unison-apt-design.md` — read it before starting. The plan argues from it and does not restate its reasoning.

## Global Constraints

- **Suites:** exactly two — Debian `trixie` and Ubuntu `resolute` (26.04). Never `debian:stable` or `ubuntu:latest`.
- **Architectures:** `amd64` and `arm64`. amd64 builds on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`.
- **Version format:** `<upstream>-1+porelli<pkgrev>~<vtag>`, where `vtag` is `deb13` for trixie and `ub2604` for resolute. Example: `2.54.0-1+porelli1~deb13`.
- **Package names:** `unison`, `unison-gtk`, `unison-apt-keyring`. The first two deliberately shadow the distro's.
- **`unison` must contain `/usr/bin/unison-fsmonitor`.** This is the project's reason to exist; assert it, never assume it.
- **`unison` must depend on no GTK package.** Only `unison-gtk` may.
- **No network access during the package build.** Downloads are workflow steps; `debian/rules` touches only the tree it is given.
- **`dpkg-scanpackages` must always be passed `--multiversion`.** Without it, retained older versions are silently unreachable.
- **Retain 3 upstream versions** in the pool: the one being published plus the two preceding it.
- **Signing key:** ed25519, no passphrase, secret name `APT_SIGNING_KEY`, armoured private key.
- **Publish target:** branch `apt-repo`, always a single orphan commit, force-pushed.
- **Scripts must be POSIX `sh`** (no bashisms) and pass `shellcheck`. They run on macOS, on GitHub runners, and inside Debian/Ubuntu containers.
- **Upstream source:** `https://github.com/bcpierce00/unison`, tag `v<upstream>`.
- **Trap to remember:** upstream's `manpage` and `docs` make targets are empty no-ops. Only `make -C src manpagefile` builds the man page.

---

## File Structure

```
unison-apt/
├── README.md                          client-facing install instructions
├── packaging/
│   ├── revision                       packaging revision, e.g. "1"
│   ├── keyring-revision               keyring package revision, e.g. "1"
│   ├── suites.tsv                     the suite matrix, as data
│   ├── repo.conf                      repo identity: name, Pages URL, maintainer
│   └── debian/                        vendored debhelper packaging, suite-independent
│       ├── control
│       ├── rules
│       ├── copyright
│       ├── source/format
│       ├── unison.install
│       ├── unison.docs
│       ├── unison-gtk.install
│       ├── unison-gtk.links
│       ├── unison-gtk.manpages
│       ├── unison-gui.1
│       └── unison-gtk.1
├── scripts/
│   ├── lib.sh                         suite lookup + version computation
│   ├── detect.sh                      is there a new version to build?
│   ├── matrix.sh                      build matrix JSON from suites.tsv + arches
│   ├── changelog.sh                   generate debian/changelog for one suite
│   ├── build-debs.sh                  build unison + unison-gtk for one suite
│   ├── make-keyring-deb.sh            build unison-apt-keyring for one suite
│   ├── make-repo.sh                   pool → signed dists/
│   ├── install-test.sh                install from the repo and prove it works
│   ├── previous-version.sh            newest retained version that is not current
│   ├── make-index.sh                  the landing page served at the repo root
│   └── publish.sh                     orphan-commit force-push
├── tests/
│   ├── assert.sh                      tiny assertion helper
│   ├── run-tests.sh                   run every tests/test-*.sh
│   ├── fixtures/
│   │   ├── suites.tsv
│   │   ├── release-2.54.0.json
│   │   └── state-2.54.0.json
│   ├── test-version.sh                unit: version + suite lookup
│   ├── test-detect.sh                 unit: detection, against fixtures
│   ├── test-matrix.sh                 unit: matrix JSON
│   ├── test-dpkg-order.sh             requires dpkg; runs in a container only
│   ├── test-deb-contents.sh           takes a deb dir; run by build-debs.sh
│   ├── test-keyring-deb.sh            takes a deb dir; run by make-keyring-deb.sh
│   └── test-repo-layout.sh            takes a repo dir; run by make-repo.sh
└── .github/workflows/
    ├── release.yml                    the pipeline
    └── probe.yml                      throwaway runner-capability probe (Task 2)
```

Responsibility boundaries worth respecting:

- `scripts/lib.sh` is the only place that knows the version format or reads `suites.tsv`. Nothing else parses either.
- `scripts/build-debs.sh` knows how to build one suite and nothing about repositories.
- `scripts/make-repo.sh` knows about apt metadata and nothing about how debs were made.
- The workflow orchestrates and holds no logic. If you find yourself writing shell in YAML beyond a single call, it belongs in a script.

---

## Task 1: Suite data and version computation

**Files:**
- Create: `packaging/suites.tsv`, `packaging/revision`, `packaging/keyring-revision`, `packaging/repo.conf`
- Create: `scripts/lib.sh`
- Create: `tests/assert.sh`, `tests/run-tests.sh`, `tests/fixtures/suites.tsv`
- Test: `tests/test-version.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/lib.sh`, sourceable, exporting shell functions
  - `suite_vendor <codename>` → `debian` | `ubuntu`
  - `suite_image  <codename>` → e.g. `debian:trixie`
  - `suite_vtag   <codename>` → e.g. `deb13`
  - `suite_list` → every codename, one per line
  - `deb_version <upstream> <pkgrev> <codename>` → e.g. `2.54.0-1+porelli1~deb13`
  - `keyring_version <krev> <codename>` → e.g. `1~deb13`
  - All return non-zero on an unknown codename.
  - Honours `SUITES_FILE` (default `packaging/suites.tsv`) so tests can point at a fixture.

- [ ] **Step 1: Write the assertion helper and runner**

`tests/assert.sh`:

```sh
# shellcheck shell=sh
# Sourced by tests/test-*.sh. Sets FAILED=1 on any failure.
FAILED=0

assert_eq() {
  _actual="$1"; _expected="$2"; _label="${3:-assert_eq}"
  if [ "$_actual" = "$_expected" ]; then
    printf 'ok   %s\n' "$_label"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$_label" "$_expected" "$_actual"
    FAILED=1
  fi
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL expected non-zero exit: %s\n' "$*"
    FAILED=1
  else
    printf 'ok   exits non-zero: %s\n' "$*"
  fi
}

assert_contains() {
  _haystack="$1"; _needle="$2"; _label="${3:-assert_contains}"
  case "$_haystack" in
    *"$_needle"*) printf 'ok   %s\n' "$_label" ;;
    *) printf 'FAIL %s\n     missing: %s\n     in:      %s\n' "$_label" "$_needle" "$_haystack"; FAILED=1 ;;
  esac
}
```

`tests/run-tests.sh`:

```sh
#!/bin/sh
# Runs every tests/test-*.sh, reports a summary, exits non-zero if any failed.
# Tests needing dpkg are skipped unless dpkg is present.
set -eu
cd "$(dirname "$0")/.."
rc=0
for t in tests/test-*.sh; do
  printf '\n=== %s ===\n' "$t"
  if sh "$t"; then :; else rc=1; fi
done
if [ "$rc" -eq 0 ]; then printf '\nall tests passed\n'; else printf '\nTESTS FAILED\n'; fi
exit "$rc"
```

- [ ] **Step 2: Write the failing test**

`tests/fixtures/suites.tsv` (tab-separated; the fixture holds an extra suite the real file does not, to prove nothing is hardcoded):

```
trixie	debian	debian:trixie	deb13
resolute	ubuntu	ubuntu:26.04	ub2604
forky	debian	debian:forky	deb14
```

`tests/test-version.sh`:

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv
export SUITES_FILE
. scripts/lib.sh

assert_eq "$(suite_vendor trixie)"   "debian"        "vendor of trixie"
assert_eq "$(suite_image trixie)"    "debian:trixie" "image of trixie"
assert_eq "$(suite_vtag trixie)"     "deb13"         "vtag of trixie"
assert_eq "$(suite_vendor resolute)" "ubuntu"        "vendor of resolute"
assert_eq "$(suite_image resolute)"  "ubuntu:26.04"  "image of resolute"
assert_eq "$(suite_vtag resolute)"   "ub2604"        "vtag of resolute"

assert_eq "$(suite_list | tr '\n' ' ')" "trixie resolute forky " "suite_list order"

assert_eq "$(deb_version 2.54.0 1 trixie)"   "2.54.0-1+porelli1~deb13"  "trixie version"
assert_eq "$(deb_version 2.54.0 1 resolute)" "2.54.0-1+porelli1~ub2604" "resolute version"
assert_eq "$(deb_version 2.55.1 3 forky)"    "2.55.1-1+porelli3~deb14"  "revision is substituted"

assert_eq "$(keyring_version 1 trixie)"   "1~deb13"  "keyring version trixie"
assert_eq "$(keyring_version 2 resolute)" "2~ub2604" "keyring version resolute"

# An unknown suite must fail loudly rather than emit a malformed version.
assert_fails suite_vtag bookworm
assert_fails deb_version 2.54.0 1 bookworm

exit "$FAILED"
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `sh tests/test-version.sh`
Expected: FAIL — `scripts/lib.sh` does not exist, so sourcing it aborts with "No such file or directory".

- [ ] **Step 4: Write the minimal implementation**

`scripts/lib.sh`:

```sh
# shellcheck shell=sh
# Suite metadata and version computation. The single source of truth for both.
#
# suites.tsv columns, tab-separated:
#   1 codename   2 vendor   3 container image   4 version tag

SUITES_FILE="${SUITES_FILE:-packaging/suites.tsv}"

# _suite_field <codename> <column> -- non-zero if the codename is unknown
_suite_field() {
  awk -F'\t' -v c="$1" -v n="$2" '
    /^#/ || /^[[:space:]]*$/ { next }
    $1 == c { print $n; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$SUITES_FILE"
}

suite_vendor() { _suite_field "$1" 2; }
suite_image()  { _suite_field "$1" 3; }
suite_vtag()   { _suite_field "$1" 4; }

suite_list() {
  awk -F'\t' '!/^#/ && !/^[[:space:]]*$/ { print $1 }' "$SUITES_FILE"
}

# deb_version <upstream> <pkgrev> <codename>
#
# The "-1+porelli<rev>" is what makes this outrank a distro package of the same
# upstream version: dpkg compares the revision "1+porelli1~deb13" against a bare
# "1" and the longer one wins. The "~<vtag>" suffix orders suites among
# themselves (deb13 < deb14), so a dist-upgrade moves forward.
deb_version() {
  _vtag="$(suite_vtag "$3")" || return 1
  printf '%s-1+porelli%s~%s\n' "$1" "$2" "$_vtag"
}

# keyring_version <keyring-revision> <codename>
keyring_version() {
  _vtag="$(suite_vtag "$2")" || return 1
  printf '%s~%s\n' "$1" "$_vtag"
}
```

`packaging/suites.tsv`:

```
# codename	vendor	container image	version tag
trixie	debian	debian:trixie	deb13
resolute	ubuntu	ubuntu:26.04	ub2604
```

`packaging/revision`:

```
1
```

`packaging/keyring-revision`:

```
1
```

`packaging/repo.conf`:

```sh
# shellcheck shell=sh
# Repository identity. Sourced by scripts that need to name or address the repo.
REPO_NAME="unison-apt"
REPO_ORIGIN="unison-apt"
REPO_LABEL="unison-apt"
REPO_URL="https://porelli.github.io/unison-apt"
REPO_DESC="Current upstream Unison, including unison-fsmonitor"
MAINTAINER="Michele Porelli <Linux571@gmail.com>"
UPSTREAM_REPO="bcpierce00/unison"
PUBLISH_BRANCH="apt-repo"
KEYRING_PKG="unison-apt-keyring"
KEYRING_FILE="unison-apt.gpg"
SOURCES_FILE="unison-apt.sources"
```

**Watch out:** `suites.tsv` is tab-separated and the awk parsing depends on it. If your editor converts tabs to spaces, every lookup fails. Verify with `cat -A packaging/suites.tsv` — you must see `^I` between fields.

- [ ] **Step 5: Run the test to confirm it passes**

Run: `sh tests/test-version.sh`
Expected: every line `ok`, exit 0.

- [ ] **Step 6: Confirm the scripts are clean POSIX shell**

Run: `shellcheck -s sh scripts/lib.sh tests/*.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add packaging scripts/lib.sh tests
git commit -m "feat: suite metadata and version computation

The version format is what makes a package outrank the distro's at the same
upstream version, so it gets a test rather than a comment. The fixture carries a
third suite the real file lacks, so a hardcoded codename fails the test."
```

---

## Task 2: Probe the Gitea runner, and prove the version scheme against real dpkg

Two claims are still unverified and everything downstream rests on them: that the Gitea runner can run job-level `container:`, and that the version strings actually sort the way Task 1 asserts. Both are cheap to check and expensive to discover late. This task exists to fail fast.

**Files:**
- Create: `tests/test-dpkg-order.sh`
- Create: `.github/workflows/probe.yml` (deleted at the end of the task)

**Interfaces:**
- Consumes: `scripts/lib.sh` from Task 1.
- Produces: a known-good answer to "does `container:` work on Gitea, and is nested docker available?", recorded in the commit message. No code that later tasks import.

- [ ] **Step 1: Write the version-ordering test**

`tests/test-dpkg-order.sh`:

```sh
#!/bin/sh
# Verifies the version scheme sorts as the spec claims. Requires dpkg, so it
# skips on machines without it (macOS) and runs in CI containers.
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh

if ! command -v dpkg >/dev/null 2>&1; then
  printf 'skip (no dpkg on this host)\n'
  exit 0
fi

gt() {
  if dpkg --compare-versions "$1" gt "$2"; then
    printf 'ok   %s > %s\n' "$1" "$2"
  else
    printf 'FAIL %s is not > %s\n' "$1" "$2"; FAILED=1
  fi
}

# Beats the distro packages we are replacing (versions checked 2026-09-16).
gt '2.54.0-1+porelli1~deb13'  '2.53+1-1'
gt '2.54.0-1+porelli1~ub2604' '2.53+1build1'

# Beats a hypothetical future distro release of the same upstream version.
# This is the property the "+porelli1" exists for; without it these would tie.
gt '2.54.0-1+porelli1~deb13'  '2.54.0-1'
gt '2.54.0-1+porelli1~ub2604' '2.54.0-1'

# Orders across a dist-upgrade.
gt '2.54.0-1+porelli1~deb14'  '2.54.0-1+porelli1~deb13'
gt '2.54.0-1+porelli1~ub2804' '2.54.0-1+porelli1~ub2604'

# A newer upstream beats an older one, and a packaging bump beats no bump.
gt '2.55.0-1+porelli1~deb13'  '2.54.0-1+porelli1~deb13'
gt '2.54.0-1+porelli2~deb13'  '2.54.0-1+porelli1~deb13'

exit "$FAILED"
```

- [ ] **Step 2: Run it locally to see it skip**

Run: `sh tests/test-dpkg-order.sh`
Expected: `skip (no dpkg on this host)`, exit 0. There is no dpkg on macOS; the container run in step 5 is what actually exercises it.

- [ ] **Step 3: Create the Gitea repo and push**

```bash
tea repos create --login claude --name unison-apt --description "apt repository for current Unison with fsmonitor" --private=false
git remote add gitea https://gitea.porelli.eu/claude/unison-apt.git
git push -u gitea main
```

Use the `claude` login's own namespace — its token can create repos there without permission questions, and this repo is disposable once GitHub is live.

- [ ] **Step 4: Write the probe workflow**

`.github/workflows/probe.yml`:

```yaml
# Throwaway. Answers three questions about a runner, then gets deleted:
#   1. does job-level `container:` work?
#   2. can we apt-get inside it?
#   3. is nested docker available (needed only for the optional QEMU arm64 path)?
name: probe
on: workflow_dispatch

jobs:
  container-support:
    runs-on: ubuntu-latest
    container: debian:trixie
    steps:
      - name: Report what we landed in
        run: |
          set -eux
          cat /etc/os-release
          uname -m
          id

      - name: apt works, and dpkg-dev installs
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends dpkg-dev git ca-certificates

      - uses: actions/checkout@v4

      - name: Version ordering against real dpkg
        run: sh tests/test-dpkg-order.sh

  nested-docker:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: Is a docker daemon reachable from inside a job?
        run: |
          set -x
          docker version || echo "NO NESTED DOCKER -- the QEMU arm64 path is unavailable here"
```

- [ ] **Step 5: Push and dispatch on Gitea**

```bash
git add tests/test-dpkg-order.sh .github/workflows/probe.yml
git commit -m "test: probe runner container support and version ordering"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt probe
```

If `tea` cannot dispatch, trigger it from the Gitea web UI (Actions → probe → Run workflow).

Expected results, and what each means:
- `container-support` **passes** → `container:` works; proceed as planned. The `test-dpkg-order.sh` output inside it also confirms every version-ordering claim against real dpkg.
- `container-support` **fails to start the container** → act_runner is not on a docker backend. **Stop and report.** The per-suite build model in the spec depends on this; do not work around it silently.
- `nested-docker` passes → the optional QEMU arm64 dry run (Task 10) is possible.
- `nested-docker` fails → that is acceptable and expected on many act_runner setups. Task 10 gets skipped and arm64's first real build is on GitHub's native arm64 runner. Record which happened.

- [ ] **Step 6: Also run the ordering test on GitHub's runner if convenient**

Not required. The dpkg version algorithm is dpkg's, not the runner's, so one container proves it everywhere.

- [ ] **Step 7: Delete the probe workflow and commit the finding**

```bash
git rm .github/workflows/probe.yml
git add -A
git commit -m "test: verify version ordering against dpkg; drop the runner probe

Records what the probe found: <container: works | container: does not work>,
nested docker <available | unavailable>. The version-ordering test stays because
the ordering claims are load-bearing and invisible to inspection; the probe
workflow goes because it has answered its question."
git push gitea main
```

Replace the angle-bracketed placeholders with what actually happened before committing.

---

## Task 3: The debhelper packaging, and a real trixie build

The biggest task, and the one that either works or teaches you something. It ends with two real `.deb` files whose contents are asserted.

**Files:**
- Create: `packaging/debian/control`, `rules`, `copyright`, `source/format`, `unison.install`, `unison.docs`, `unison-gtk.install`, `unison-gtk.links`, `unison-gtk.manpages`, `unison-gui.1`, `unison-gtk.1`
- Create: `scripts/changelog.sh`, `scripts/build-debs.sh`
- Create: `tests/test-deb-contents.sh`
- Create: `.github/workflows/release.yml` (build job only; later tasks extend it)

**Interfaces:**
- Consumes: `scripts/lib.sh` (`deb_version`, `suite_image`).
- Produces:
  - `scripts/changelog.sh <upstream> <pkgrev> <codename> <outfile>` — writes a `debian/changelog`.
  - `scripts/build-debs.sh <upstream> <codename> <outdir>` — run *inside* a container of that suite; leaves `unison_<v>_<arch>.deb` and `unison-gtk_<v>_<arch>.deb` in `<outdir>`.
  - `tests/test-deb-contents.sh <debdir> <expected-version>` — asserts the contents of debs in a directory.

- [ ] **Step 1: Write the failing content assertions**

`tests/test-deb-contents.sh`:

```sh
#!/bin/sh
# Asserts what the built packages must contain.
# usage: test-deb-contents.sh <deb-dir> <expected-version>
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh

debdir="${1:?usage: test-deb-contents.sh <deb-dir> <expected-version>}"
want_version="${2:?expected version required}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'skip (no dpkg-deb on this host)\n'
  exit 0
fi

unison_deb="$(ls "$debdir"/unison_*.deb 2>/dev/null | head -1 || true)"
gtk_deb="$(ls "$debdir"/unison-gtk_*.deb 2>/dev/null | head -1 || true)"

if [ -z "$unison_deb" ]; then printf 'FAIL no unison_*.deb in %s\n' "$debdir"; exit 1; fi
if [ -z "$gtk_deb" ];    then printf 'FAIL no unison-gtk_*.deb in %s\n' "$debdir"; exit 1; fi

u_files="$(dpkg-deb -c "$unison_deb")"
g_files="$(dpkg-deb -c "$gtk_deb")"
u_ctrl="$(dpkg-deb -f "$unison_deb")"
g_ctrl="$(dpkg-deb -f "$gtk_deb")"

# The entire point of the project.
assert_contains "$u_files" "./usr/bin/unison-fsmonitor" "unison ships unison-fsmonitor"
assert_contains "$u_files" "./usr/bin/unison"           "unison ships unison"
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

assert_contains "$g_files" "./usr/bin/unison-gui" "unison-gtk ships unison-gui"
assert_contains "$g_files" "./usr/bin/unison-gtk" "unison-gtk ships the compat symlink"
assert_contains "$g_files" "unison-gui.desktop"   "unison-gtk ships the desktop entry"
assert_contains "$g_files" "icons/hicolor"        "unison-gtk ships icons"
assert_eq "$(printf '%s\n' "$g_ctrl" | awk '/^Version:/{print $2}')" \
          "$want_version" "unison-gtk version field"
assert_contains "$g_ctrl" "unison (= $want_version)" "unison-gtk pins unison to the same version"

exit "$FAILED"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `sh tests/test-deb-contents.sh /tmp/nonexistent 2.54.0-1+porelli1~deb13`
Expected: FAIL — `no unison_*.deb in /tmp/nonexistent`. (On macOS the `dpkg-deb` skip fires first; that is fine, the container run in step 7 is the real gate.)

- [ ] **Step 3: Write the packaging**

`packaging/debian/control`:

```
Source: unison
Section: net
Priority: optional
Maintainer: Michele Porelli <Linux571@gmail.com>
Build-Depends: debhelper-compat (= 13),
               ocaml-nox | ocaml,
               ocaml-findlib,
               liblablgtk3-ocaml-dev,
               pkg-config
Standards-Version: 4.7.0
Homepage: https://github.com/bcpierce00/unison
Rules-Requires-Root: no

Package: unison
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}
Provides: unison-fsmonitor
Description: file synchronization tool, with fsmonitor
 Unison is a file synchronization tool for POSIX systems and Windows. Two
 replicas of a collection of files and directories can be stored on different
 hosts, modified separately, and then brought up to date by propagating the
 changes in each replica to the other.
 .
 This package is built from the current upstream release and, unlike the
 distribution's own unison package, includes unison-fsmonitor. Without that
 binary "unison -repeat watch" cannot work and continuous synchronization
 degrades to polling.
 .
 Note that Unison requires the same version at both ends of a synchronization.

Package: unison-gtk
Architecture: any
Depends: unison (= ${binary:Version}), ${shlibs:Depends}, ${misc:Depends}
Description: file synchronization tool, with fsmonitor (GTK interface)
 Unison is a file synchronization tool for POSIX systems and Windows. Two
 replicas of a collection of files and directories can be stored on different
 hosts, modified separately, and then brought up to date by propagating the
 changes in each replica to the other.
 .
 This package provides the GTK graphical interface, installed as unison-gui
 with a unison-gtk compatibility symlink, along with the desktop entry and
 icons that upstream ships and the distribution's packages omit.
```

**Note on `ocaml-nox | ocaml`:** this alternative is not cosmetic. Debian trixie has both packages; **Ubuntu resolute has only `ocaml`**. A bare `ocaml-nox` build-dependency makes every resolute build fail with an unsatisfiable dependency.

`packaging/debian/rules`:

```makefile
#!/usr/bin/make -f

%:
	dh $@

# Upstream's default target already builds the text UI, the GUI when lablgtk3 is
# present, and fsmonitor. The targets are named explicitly so a missing lablgtk3
# fails here, loudly, rather than silently yielding a package with no GUI.
override_dh_auto_build:
	$(MAKE) tui fsmonitor gui
	# NOT `make manpage` -- upstream's manpage and docs targets are empty
	# no-ops. Only manpagefile builds anything, by expanding man/unison.1.in
	# with the freshly built binary's -prefsman output.
	$(MAKE) -C src manpagefile
	./src/unison -doc all > unison-manual.txt
	test -s man/unison.1
	test -s unison-manual.txt

override_dh_auto_test:
ifeq (,$(filter nocheck,$(DEB_BUILD_OPTIONS)))
	mkdir -p debian/.home
	HOME=$(CURDIR)/debian/.home $(MAKE) test
endif

# Upstream's install target honours DESTDIR and PREFIX and places the binaries,
# man page, desktop entry and icon theme files. Stage it all, then let the
# per-package .install files split it.
override_dh_auto_install:
	$(MAKE) install DESTDIR=$(CURDIR)/debian/tmp PREFIX=/usr

override_dh_installchangelogs:
	dh_installchangelogs NEWS.md

override_dh_auto_clean:
	-$(MAKE) clean
	rm -rf debian/.home unison-manual.txt
```

`packaging/debian/source/format`:

```
3.0 (quilt)
```

`packaging/debian/unison.install`:

```
usr/bin/unison
usr/bin/unison-fsmonitor
usr/share/man/man1/unison.1
```

`packaging/debian/unison.docs`:

```
unison-manual.txt
README.md
```

`packaging/debian/unison-gtk.install`:

```
usr/bin/unison-gui
usr/share/applications/unison-gui.desktop
usr/share/icons/hicolor
```

`packaging/debian/unison-gtk.links`:

```
usr/bin/unison-gui usr/bin/unison-gtk
```

`packaging/debian/unison-gtk.manpages`:

```
debian/unison-gui.1
debian/unison-gtk.1
```

`packaging/debian/unison-gui.1` and `packaging/debian/unison-gtk.1` — both are this single line, because the GUI takes the same options as the CLI and duplicating 18 KB of man page would create two things to keep in sync:

```
.so man1/unison.1
```

`packaging/debian/copyright`:

```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: unison
Upstream-Contact: https://github.com/bcpierce00/unison/issues
Source: https://github.com/bcpierce00/unison

Files: *
Copyright: 1999-2026 Benjamin C. Pierce and the Unison contributors
License: GPL-3+

Files: debian/*
Copyright: 2026 Michele Porelli <Linux571@gmail.com>
License: GPL-3+

License: GPL-3+
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 .
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 .
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 .
 On Debian systems, the complete text of the GNU General Public License
 version 3 can be found in "/usr/share/common-licenses/GPL-3".
```

- [ ] **Step 4: Write the changelog generator**

`scripts/changelog.sh`:

```sh
#!/bin/sh
# Generate a debian/changelog for one suite.
# usage: changelog.sh <upstream> <pkgrev> <codename> <outfile>
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
. packaging/repo.conf

upstream="${1:?upstream version required}"
pkgrev="${2:?packaging revision required}"
codename="${3:?codename required}"
out="${4:?output file required}"

version="$(deb_version "$upstream" "$pkgrev" "$codename")"

# Reproducible when SOURCE_DATE_EPOCH is set (dpkg sets it from the changelog,
# so seed it from the environment where available).
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  stamp="$(date -u -R -d "@$SOURCE_DATE_EPOCH" 2>/dev/null || date -R)"
else
  stamp="$(date -R)"
fi

cat > "$out" <<EOF
unison ($version) $codename; urgency=medium

  * Automated build of upstream $upstream for $codename.
  * Includes unison-fsmonitor, which the distribution's package omits.

 -- $MAINTAINER  $stamp
EOF
```

- [ ] **Step 5: Write the build script**

`scripts/build-debs.sh`:

```sh
#!/bin/sh
# Build unison and unison-gtk for one suite. Runs INSIDE a container of that
# suite -- it installs build dependencies, so do not run it on your laptop.
#
# usage: build-debs.sh <upstream> <codename> <outdir>
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
. scripts/lib.sh
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
```

**Note:** `apt-get build-dep -y ./` reads `debian/control` directly and needs no `deb-src` entries. That is why the build-dependency list lives in exactly one place.

- [ ] **Step 6: Write the build job**

`.github/workflows/release.yml` — the build job only; Tasks 5–9 extend this file:

```yaml
name: release
on:
  workflow_dispatch:
    inputs:
      version:
        description: upstream version to build (e.g. 2.54.0)
        type: string
        required: true

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - suite: trixie
            image: debian:trixie
            runner: ubuntu-latest
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.image }}
    steps:
      - name: Install git for checkout
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates

      - uses: actions/checkout@v4

      - name: Build
        run: sh scripts/build-debs.sh "${{ inputs.version }}" "${{ matrix.suite }}" "$PWD/out"

      - uses: actions/upload-artifact@v4
        with:
          name: debs-${{ matrix.suite }}-amd64
          path: out/*.deb
```

- [ ] **Step 7: Run it on Gitea and iterate until green**

```bash
shellcheck -s sh scripts/*.sh tests/*.sh
git add packaging/debian scripts tests .github
git commit -m "feat: debhelper packaging and a per-suite build script"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt release -f version=2.54.0
```

Expected: green, with `tests/test-deb-contents.sh` reporting every assertion `ok`, and two artifacts.

Failures you should expect to work through, and what they mean:
- **`make test` fails or hangs** — the self-test syncs real directories. Confirm `HOME` is set (the `rules` override does this). If it is flaky in a container, set `DEB_BUILD_OPTIONS=nocheck` for that run to isolate whether the *build* is fine, then fix the test separately rather than deleting the gate.
- **`dh_install` cannot find `usr/bin/unison-gui`** — the GUI did not build, meaning lablgtk3 was not detected. Check that `liblablgtk3-ocaml-dev` actually installed, and that `make gui` was reached.
- **`dh_install` cannot find `usr/share/man/man1/unison.1`** — `manpagefile` did not run or failed. This is the empty-no-op trap; confirm `rules` calls `$(MAKE) -C src manpagefile` and not `make manpage`.
- **`ldd -r` reports missing symbols** — a real linkage problem; do not suppress it.

- [ ] **Step 8: Commit the working state**

If step 7 needed no changes, there is nothing to commit and this step is done.
If it did, commit them describing the actual defect and its cause — not "fix
build". A future reader needs to know which of the four failure modes above bit
you.

```bash
git add -A
git commit -m "fix: <the actual defect, e.g. 'rules called make manpage, which is a no-op'>"
git push gitea main
```

---

## Task 4: Add resolute, the riskiest suite

Resolute ships OCaml 5.4, newer than anything upstream's CI tests. Adding it as its own task keeps a compiler incompatibility from being tangled up with packaging bugs.

**Files:**
- Modify: `.github/workflows/release.yml` (matrix gains resolute)

**Interfaces:**
- Consumes: everything from Task 3, unchanged. If this task requires changes to `packaging/debian/*`, they must not break trixie — both suites are in the matrix and both must stay green.

- [ ] **Step 1: Add resolute to the matrix**

In `.github/workflows/release.yml`, extend `matrix.include`:

```yaml
        include:
          - suite: trixie
            image: debian:trixie
            runner: ubuntu-latest
          - suite: resolute
            image: ubuntu:26.04
            runner: ubuntu-latest
```

- [ ] **Step 2: Run it and watch resolute specifically**

```bash
git add .github/workflows/release.yml
git commit -m "test: build resolute too, where OCaml is 5.4"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt release -f version=2.54.0
```

Expected: both suites green, and `test-deb-contents.sh` asserting
`2.54.0-1+porelli1~ub2604` for resolute.

- [ ] **Step 3: If resolute fails to compile under OCaml 5.4**

Do not patch upstream's source blindly. In order of preference:
1. Read the actual error. If it is a warning promoted to an error, the fix belongs in `rules` as a documented flag, not in the source.
2. Check whether upstream has a newer release or a commit addressing OCaml 5.4.
3. If it is genuinely upstream-incompatible, **stop and report**. Dropping resolute is a scope decision for the user, not a workaround to apply quietly. The spec named this as risk 1 precisely so this moment has an owner.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: build for Ubuntu resolute

OCaml 5.4 is newer than upstream's CI covers, so this suite gets its own commit;
if it breaks later, the diff that added it is not tangled with packaging work."
git push gitea main
```

---

## Task 5: The signing key and the keyring package

**Files:**
- Create: `scripts/make-keyring-deb.sh`
- Create: `tests/test-keyring-deb.sh`
- Create: `docs/key-management.md`

**Interfaces:**
- Consumes: `scripts/lib.sh` (`keyring_version`, `suite_list`), `packaging/repo.conf`.
- Produces: `scripts/make-keyring-deb.sh <codename> <pubkey-file> <outdir>` → `<outdir>/unison-apt-keyring_<krev>~<vtag>_all.deb`.

- [ ] **Step 1: Generate the signing key**

Run locally, once. `gpg` is present on macOS via the system or brew; if absent, `brew install gnupg`.

```bash
gpg --batch --quick-generate-key "unison-apt repository signing key <Linux571@gmail.com>" ed25519 sign never
gpg --list-secret-keys --keyid-format=long
```

Capture the long key id, then export both halves:

```bash
KEYID=<the long key id>
gpg --armor --export "$KEYID" > /tmp/unison-apt.asc
gpg --armor --export-secret-keys "$KEYID" > /tmp/unison-apt-secret.asc
```

`--quick-generate-key` with `never` as the last argument creates the key with **no passphrase and no expiry**. No expiry is deliberate: an expired repository key breaks `apt update` on every client at once, with an error that reads like a compromise.

- [ ] **Step 2: Store the secret and record the public key**

```bash
# Gitea
tea secret create --login claude --repo claude/unison-apt APT_SIGNING_KEY --value "$(cat /tmp/unison-apt-secret.asc)"
```

If `tea secret create` is unavailable in this version, add it via the Gitea web UI: repo → Settings → Actions → Secrets.

Then commit the *public* key into the repo and delete the private copy from disk:

```bash
mkdir -p packaging/keys
cp /tmp/unison-apt.asc packaging/keys/unison-apt.asc
rm -f /tmp/unison-apt-secret.asc /tmp/unison-apt.asc
```

**The private key must never be committed.** Add a guard so a future mistake fails loudly — `.gitignore`:

```
*-secret.asc
*.gpg
!packaging/keys/*.asc
```

- [ ] **Step 3: Write the failing test**

`tests/test-keyring-deb.sh`:

```sh
#!/bin/sh
# usage: test-keyring-deb.sh <deb-dir> <codename>
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
. packaging/repo.conf

debdir="${1:?deb dir required}"
codename="${2:?codename required}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'skip (no dpkg-deb on this host)\n'
  exit 0
fi

deb="$(ls "$debdir"/${KEYRING_PKG}_*_all.deb 2>/dev/null | head -1 || true)"
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
dpkg-deb --fsys-tarfile "$deb" | tar -xO ./usr/share/keyrings/"$KEYRING_FILE" > /tmp/kr.gpg
if head -c 100 /tmp/kr.gpg | grep -q 'BEGIN PGP'; then
  printf 'FAIL keyring is ASCII-armoured; it must be dearmoured\n'; FAILED=1
else
  printf 'ok   keyring is binary\n'
fi

# conffile, so a local edit survives upgrades
assert_contains "$(dpkg-deb -I "$deb" conffiles 2>/dev/null || echo '')" \
  "/etc/apt/sources.list.d/$SOURCES_FILE" "sources file is a conffile"

exit "$FAILED"
```

- [ ] **Step 4: Run it to confirm it fails**

Run: `sh tests/test-keyring-deb.sh /tmp/empty trixie`
Expected: FAIL (or `skip` on macOS, where the container run is the real gate).

- [ ] **Step 5: Write the builder**

`scripts/make-keyring-deb.sh`:

```sh
#!/bin/sh
# Build the unison-apt-keyring package for one suite.
# usage: make-keyring-deb.sh <codename> <pubkey.asc> <outdir>
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
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
```

- [ ] **Step 6: Verify it inside a container**

Add a temporary job to `.github/workflows/release.yml`, or extend the build job with a step (the build job already runs in a suite container and has `dpkg-deb`):

```yaml
      - name: Build the keyring package
        run: |
          set -eux
          apt-get install -y --no-install-recommends gnupg
          sh scripts/make-keyring-deb.sh "${{ matrix.suite }}" packaging/keys/unison-apt.asc "$PWD/out"
```

Run it: `tea workflow run --login claude --repo claude/unison-apt release -f version=2.54.0`
Expected: `test-keyring-deb.sh` reports every assertion `ok`, and `out/` holds a third deb.

- [ ] **Step 7: Document key management**

`docs/key-management.md`:

```markdown
# Signing key

The repository is signed by a dedicated ed25519 key with **no passphrase and no
expiry**. See the spec's "Signing key" section for why passphrase-less, and note
that its original justification (reprepro's gpgme) no longer applies — signing
now calls gpg directly, so adding a passphrase is a small change if wanted.

No expiry is deliberate. An expired repository key breaks `apt update` on every
client simultaneously, with an error that reads like a compromise.

- Private key: the `APT_SIGNING_KEY` secret, armoured. Nowhere else.
- Public key: `packaging/keys/unison-apt.asc`, also published at
  `$REPO_URL/unison-apt.asc` and shipped dearmoured inside `unison-apt-keyring`.

## Rotation, including after a compromise

1. Generate the new key.
2. Publish an `unison-apt-keyring` that contains **both** the old and new public
   keys, and bump `packaging/keyring-revision`. A keyring can hold several keys;
   apt accepts a Release signed by any of them.
3. Keep signing with the old key until clients have had time to upgrade.
4. Switch `APT_SIGNING_KEY` to the new key and re-run the workflow.
5. Once satisfied, publish a keyring with only the new key and bump the revision
   again.

Skipping step 2 breaks `apt update` for every client until each one manually
reinstalls the keyring.
```

- [ ] **Step 8: Commit**

```bash
shellcheck -s sh scripts/make-keyring-deb.sh tests/test-keyring-deb.sh
git add -A
git commit -m "feat: signing key and the keyring bootstrap package

The keyring must be dearmoured -- apt's Signed-By rejects armour in a .gpg file,
and the failure looks like a bad signature rather than a bad format, so it gets
an assertion. The key has no expiry on purpose: an expired repository key breaks
apt update everywhere at once with an error that reads like a compromise."
git push gitea main
```

---

## Task 6: Assemble and sign the repository

**Files:**
- Create: `scripts/make-repo.sh`
- Create: `tests/test-repo-layout.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh`, `packaging/repo.conf`, a populated `<repo>/pool/<suite>/main/...`.
- Produces: `scripts/make-repo.sh <repo-dir> <keyid> <arches...>` → writes `<repo>/dists/<suite>/main/binary-<arch>/Packages{,.gz}`, `<repo>/dists/<suite>/{Release,InRelease,Release.gpg}`.

- [ ] **Step 1: Write the failing test**

`tests/test-repo-layout.sh`:

```sh
#!/bin/sh
# usage: test-repo-layout.sh <repo-dir> <arch> [more-arches...]
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
. scripts/lib.sh
. packaging/repo.conf

repo="${1:?repo dir required}"; shift
arches="$*"
[ -n "$arches" ] || { echo "at least one arch required" >&2; exit 1; }

for suite in $(suite_list); do
  rel="$repo/dists/$suite/Release"
  assert_eq "$([ -s "$rel" ] && echo yes || echo no)" yes "$suite has a Release"
  assert_eq "$([ -s "$repo/dists/$suite/InRelease" ] && echo yes || echo no)" yes "$suite has InRelease"
  assert_eq "$([ -s "$repo/dists/$suite/Release.gpg" ] && echo yes || echo no)" yes "$suite has Release.gpg"

  relbody="$(cat "$rel")"
  assert_contains "$relbody" "Codename: $suite"     "$suite Release names its codename"
  assert_contains "$relbody" "Origin: $REPO_ORIGIN" "$suite Release has an Origin"
  # 'all' must NOT be advertised: arch:all packages are folded into each
  # per-arch index instead, and a binary-all/ index is not consulted by
  # older clients.
  case "$relbody" in
    *"Architectures: "*" all"*|*"Architectures: all"*)
      printf 'FAIL %s Release advertises architecture all\n' "$suite"; FAILED=1 ;;
    *) printf 'ok   %s Release does not advertise all\n' "$suite" ;;
  esac

  for arch in $arches; do
    p="$repo/dists/$suite/main/binary-$arch/Packages"
    assert_eq "$([ -s "$p" ] && echo yes || echo no)" yes "$suite/$arch has Packages"
    assert_eq "$([ -s "$p.gz" ] && echo yes || echo no)" yes "$suite/$arch has Packages.gz"

    body="$(cat "$p")"
    assert_contains "$body" "Package: unison"      "$suite/$arch indexes unison"
    assert_contains "$body" "Package: unison-gtk"  "$suite/$arch indexes unison-gtk"
    # The arch:all keyring package must appear in EVERY per-arch index.
    assert_contains "$body" "Package: $KEYRING_PKG" "$suite/$arch indexes the keyring"

    # Filename paths must be relative to the repository root, or apt 404s.
    case "$body" in
      *"Filename: pool/$suite/main/"*) printf 'ok   %s/%s Filename is repo-relative\n' "$suite" "$arch" ;;
      *) printf 'FAIL %s/%s has no repo-relative Filename\n' "$suite" "$arch"; FAILED=1 ;;
    esac

    # No foreign architecture leaked in.
    for other in $arches; do
      [ "$other" = "$arch" ] && continue
      case "$body" in
        *"Architecture: $other"*)
          printf 'FAIL %s/%s index contains %s packages\n' "$suite" "$arch" "$other"; FAILED=1 ;;
        *) : ;;
      esac
    done
  done
done

exit "$FAILED"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `sh tests/test-repo-layout.sh /tmp/norepo amd64`
Expected: FAIL — no Release for trixie.

- [ ] **Step 3: Write the implementation**

`scripts/make-repo.sh`:

```sh
#!/bin/sh
# Turn a populated pool into signed apt metadata.
# usage: make-repo.sh <repo-dir> <keyid> <arch> [arch...]
#
# Expects <repo-dir>/pool/<suite>/main/u/<src>/*.deb to already exist.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
. scripts/lib.sh
. packaging/repo.conf

repo="${1:?repo dir required}"; shift
keyid="${1:?gpg key id required}"; shift
arches="$*"
[ -n "$arches" ] || { echo "at least one architecture required" >&2; exit 1; }

repo="$(cd "$repo" && pwd)"

for suite in $(suite_list); do
  [ -d "$repo/pool/$suite" ] || { echo "no pool for $suite, skipping" >&2; continue; }

  for arch in $arches; do
    mkdir -p "$repo/dists/$suite/main/binary-$arch"
    # --multiversion is what keeps older retained versions reachable; without
    # it only the newest version of each package is indexed and the rest sit
    # in the pool unreferenced.
    # --arch matches *_all.deb and *_<arch>.deb, which is how the arch:all
    # keyring package lands in every per-arch index.
    ( cd "$repo" && dpkg-scanpackages --multiversion --arch "$arch" "pool/$suite" ) \
      > "$repo/dists/$suite/main/binary-$arch/Packages"
    gzip -9nkf "$repo/dists/$suite/main/binary-$arch/Packages"
  done

  # apt-ftparchive checksums everything under the directory it is given, so the
  # output must not be written there while it runs.
  tmprel="$(mktemp)"
  ( cd "$repo" && apt-ftparchive \
      -o "APT::FTPArchive::Release::Origin=$REPO_ORIGIN" \
      -o "APT::FTPArchive::Release::Label=$REPO_LABEL" \
      -o "APT::FTPArchive::Release::Suite=$suite" \
      -o "APT::FTPArchive::Release::Codename=$suite" \
      -o "APT::FTPArchive::Release::Architectures=$arches" \
      -o "APT::FTPArchive::Release::Components=main" \
      -o "APT::FTPArchive::Release::Description=$REPO_DESC ($suite)" \
      release "dists/$suite" ) > "$tmprel"
  mv "$tmprel" "$repo/dists/$suite/Release"

  rm -f "$repo/dists/$suite/InRelease" "$repo/dists/$suite/Release.gpg"
  gpg --batch --yes --local-user "$keyid" \
      --clearsign -o "$repo/dists/$suite/InRelease" "$repo/dists/$suite/Release"
  gpg --batch --yes --local-user "$keyid" --armor \
      --detach-sign -o "$repo/dists/$suite/Release.gpg" "$repo/dists/$suite/Release"
done

sh "$root/tests/test-repo-layout.sh" "$repo" $arches
```

**Two traps encoded above.** Writing `Release` into the directory `apt-ftparchive release` is scanning makes it checksum a partially written copy of itself; hence the temp file. And `gpg --clearsign` refuses to overwrite an existing output file, so stale `InRelease`/`Release.gpg` must be removed first — on a re-run without that, signing fails with a confusing message about the output file.

- [ ] **Step 4: Wire a repo job into the workflow**

Extend `.github/workflows/release.yml`:

```yaml
  repo:
    needs: build
    runs-on: ubuntu-latest
    container: debian:trixie
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends \
            git ca-certificates dpkg-dev apt-utils gnupg

      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          pattern: debs-*
          path: incoming

      - name: Lay out the pool
        run: |
          set -eux
          for d in incoming/debs-*; do
            suite="$(basename "$d" | cut -d- -f2)"
            mkdir -p "repo/pool/$suite/main/u/unison"
            cp "$d"/*.deb "repo/pool/$suite/main/u/unison/"
          done
          find repo -name '*.deb' | sort

      - name: Import the signing key
        env:
          APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
        run: |
          set -eu
          printf '%s' "$APT_SIGNING_KEY" | gpg --batch --import
          gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}' > keyid.txt
          echo "imported $(cat keyid.txt)"

      - name: Assemble and sign
        run: sh scripts/make-repo.sh "$PWD/repo" "$(cat keyid.txt)" amd64

      - uses: actions/upload-artifact@v4
        with:
          name: repo
          path: repo
```

Note the pool path derives the suite from the artifact name, which is why Task 3
named artifacts `debs-<suite>-<arch>`. Keep that convention.

- [ ] **Step 5: Run it**

```bash
shellcheck -s sh scripts/make-repo.sh tests/test-repo-layout.sh
git add -A
git commit -m "feat: assemble and sign the apt repository"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt release -f version=2.54.0
```

Expected: `test-repo-layout.sh` all `ok`, and a `repo` artifact containing `dists/` and `pool/`.

- [ ] **Step 6: Commit**

Only if step 5 required changes. Name the specific cause — the two traps in this
script (self-checksumming `Release`, gpg refusing to overwrite) both produce
misleading errors, so record which one you hit.

```bash
git add -A
git commit -m "fix: <the actual cause, e.g. 'stale InRelease made gpg --clearsign refuse to write'>"
git push gitea main
```

---

## Task 7: Prove it by installing from it

Everything so far shows files exist. This shows the repository works.

**Files:**
- Create: `scripts/install-test.sh`

**Interfaces:**
- Consumes: a repo tree from Task 6, the keyring deb from Task 5.
- Produces: `scripts/install-test.sh <repo-dir> <codename> <expected-version> [previous-version]` — exits non-zero if anything is wrong. Run inside a container of `<codename>`.

- [ ] **Step 1: Write the test — it is the deliverable**

`scripts/install-test.sh`:

```sh
#!/bin/sh
# Install from a locally served copy of the repository and prove it works.
# Runs INSIDE a container of the target suite; it modifies apt configuration.
#
# usage: install-test.sh <repo-dir> <codename> <expected-version> [previous-version]
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
. packaging/repo.conf

repo="${1:?repo dir required}"
codename="${2:?codename required}"
want="${3:?expected version required}"
previous="${4:-}"
repo="$(cd "$repo" && pwd)"

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
if printf '%s\n' "$inst" | grep -qiE '^libgtk|^libx11-[0-9]|^libcairo2$'; then
  echo "FAIL installing unison alone pulled in GUI libraries:" >&2
  printf '%s\n' "$inst" | grep -iE '^libgtk|^libx11-[0-9]|^libcairo2$' >&2
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
```

- [ ] **Step 2: Add the bootstrap layout and an install-test job**

The script expects `repo/bootstrap/<codename>/<keyring>.deb`. Add that to the repo job in `.github/workflows/release.yml`, after "Lay out the pool":

```yaml
      - name: Build the keyring packages and the bootstrap tree
        run: |
          set -eux
          apt-get install -y --no-install-recommends gnupg
          for suite in $(sh -c '. scripts/lib.sh; suite_list'); do
            mkdir -p "repo/bootstrap/$suite" "repo/pool/$suite/main/u/unison"
            sh scripts/make-keyring-deb.sh "$suite" packaging/keys/unison-apt.asc "repo/bootstrap/$suite"
            cp "repo/bootstrap/$suite"/*.deb "repo/pool/$suite/main/u/unison/"
          done
          cp packaging/keys/unison-apt.asc repo/unison-apt.asc
```

The keyring deb is copied into the pool as well as the bootstrap directory, so
it can be upgraded by apt later, not only fetched by hand.

Then a new job:

```yaml
  install-test:
    needs: repo
    strategy:
      fail-fast: false
      matrix:
        include:
          - suite: trixie
            image: debian:trixie
            runner: ubuntu-latest
          - suite: resolute
            image: ubuntu:26.04
            runner: ubuntu-latest
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.image }}
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates

      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: repo
          path: repo

      - name: Install from the repository and sync for real
        run: |
          set -eu
          version="$(sh -c '. scripts/lib.sh; deb_version '"${{ inputs.version }}"' $(cat packaging/revision) ${{ matrix.suite }}')"
          sh scripts/install-test.sh "$PWD/repo" "${{ matrix.suite }}" "$version"
```

- [ ] **Step 3: Run it**

```bash
shellcheck -s sh scripts/install-test.sh
git add -A
git commit -m "feat: install from the built repository and prove fsmonitor works"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt release -f version=2.54.0
```

Expected: `ALL INSTALL TESTS PASSED` for both suites.

Failures and what they mean:
- **`apt-get update` reports a bad signature** — the keyring is armoured where it must be dearmoured, or `Release` was modified after signing.
- **`apt-get update` cannot find `Packages`** — the `Filename:` paths or the `dists/` layout are wrong. `curl` the URLs from inside the container to see what apt sees.
- **candidate is not our version** — the version scheme does not outrank the distro's. Re-read `tests/test-dpkg-order.sh`; the assertion there and the reality here disagree.
- **initial sync works but the live change does not** — this is the failure the whole project exists to prevent. `unison-fsmonitor` is present but not functioning; read `/tmp/unison-watch.log`.

- [ ] **Step 4: Commit**

Only if step 3 required changes. If the failure was the live-change propagation,
say so explicitly in the message: that is the one failure this whole project
exists to prevent, and it deserves to be findable in the log.

```bash
git add -A
git commit -m "fix: <the actual cause, e.g. 'keyring shipped armoured, so apt rejected the signature'>"
git push gitea main
```

---

## Task 8: Detection, retention, and publishing

**Files:**
- Create: `scripts/detect.sh`, `scripts/matrix.sh`, `scripts/publish.sh`
- Create: `tests/fixtures/release-2.54.0.json`, `tests/fixtures/state-2.54.0.json`
- Create: `tests/test-detect.sh`, `tests/test-matrix.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh`, `packaging/repo.conf`.
- Produces:
  - `scripts/detect.sh [--state <file>] [--force] [--version <v>]` → prints `upstream=<v>`, `target=<v>+porelli<rev>`, `changed=true|false`, one per line. Honours `UNISON_RELEASE_JSON` (a file path) instead of the network, for tests.
  - `scripts/matrix.sh <arch> [arch...]` → one line of JSON: `{"include":[{"suite":…,"image":…,"arch":…,"runner":…}]}`.
  - `scripts/publish.sh <repo-dir> <remote> <branch> <message>` → force-pushes a single orphan commit.

- [ ] **Step 1: Write the fixtures and failing tests**

`tests/fixtures/release-2.54.0.json` (only the field that matters):

```json
{ "tag_name": "v2.54.0", "name": "v2.54.0", "prerelease": false }
```

`tests/fixtures/state-2.54.0.json`:

```json
{ "upstream": "2.54.0", "pkgrev": "1", "target": "2.54.0+porelli1" }
```

`tests/test-detect.sh`:

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv; export SUITES_FILE
UNISON_RELEASE_JSON=tests/fixtures/release-2.54.0.json; export UNISON_RELEASE_JSON

get() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{print $2}'; }

# No state at all: everything is new.
out="$(sh scripts/detect.sh --state /nonexistent)"
assert_eq "$(get "$out" upstream)" "2.54.0"          "upstream parsed from tag_name"
assert_eq "$(get "$out" target)"   "2.54.0+porelli1" "target includes the packaging revision"
assert_eq "$(get "$out" changed)"  "true"            "no state means changed"

# State matching the target: nothing to do.
out="$(sh scripts/detect.sh --state tests/fixtures/state-2.54.0.json)"
assert_eq "$(get "$out" changed)" "false" "matching state means unchanged"

# --force overrides an identical state.
out="$(sh scripts/detect.sh --state tests/fixtures/state-2.54.0.json --force)"
assert_eq "$(get "$out" changed)" "true" "force overrides"

# An explicit version wins over the release feed.
out="$(sh scripts/detect.sh --state /nonexistent --version 2.55.1)"
assert_eq "$(get "$out" upstream)" "2.55.1" "explicit version wins"
assert_eq "$(get "$out" changed)"  "true"   "explicit new version is changed"

exit "$FAILED"
```

`tests/test-matrix.sh`:

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tests/assert.sh
SUITES_FILE=tests/fixtures/suites.tsv; export SUITES_FILE

out="$(sh scripts/matrix.sh amd64)"
assert_contains "$out" '"suite":"trixie"'          "trixie present"
assert_contains "$out" '"suite":"resolute"'        "resolute present"
assert_contains "$out" '"image":"ubuntu:26.04"'    "resolute image"
assert_contains "$out" '"arch":"amd64"'            "amd64 present"
assert_contains "$out" '"runner":"ubuntu-latest"'  "amd64 runner"
case "$out" in *arm64*) printf 'FAIL arm64 present when not requested\n'; FAILED=1;; *) printf 'ok   arm64 absent\n';; esac

out="$(sh scripts/matrix.sh amd64 arm64)"
assert_contains "$out" '"arch":"arm64"'                "arm64 present when asked"
assert_contains "$out" '"runner":"ubuntu-24.04-arm"'   "arm64 runner is the native one"

# Three suites in the fixture x two arches = six entries.
assert_eq "$(printf '%s' "$out" | tr ',' '\n' | grep -c '"suite"')" "6" "one entry per suite x arch"

exit "$FAILED"
```

- [ ] **Step 2: Run both to confirm they fail**

Run: `sh tests/test-detect.sh; sh tests/test-matrix.sh`
Expected: both fail — the scripts do not exist.

- [ ] **Step 3: Write detect.sh**

```sh
#!/bin/sh
# Decide whether there is a new version worth building.
# usage: detect.sh [--state <file>] [--force] [--version <v>]
# Prints key=value lines: upstream, target, changed
#
# Set UNISON_RELEASE_JSON to a file path to read the release feed from disk
# instead of the network (used by the tests).
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
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
```

- [ ] **Step 4: Write matrix.sh**

```sh
#!/bin/sh
# Emit the build matrix as one line of JSON.
# usage: matrix.sh <arch> [arch...]
set -eu
cd "$(dirname "$0")/.."
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
```

- [ ] **Step 5: Write publish.sh**

```sh
#!/bin/sh
# Publish a repository tree as a single orphan commit, force-pushed.
# usage: publish.sh <repo-dir> <remote-url> <branch> <message>
#
# A fresh `git init` in the tree gives an orphan branch for free: there is no
# history to inherit, so the branch is always exactly one commit and years of
# published debs never accumulate in git.
set -eu
. "$(dirname "$0")/../packaging/repo.conf"

repo="${1:?repo dir required}"
remote="${2:?remote url required}"
branch="${3:?branch required}"
message="${4:?commit message required}"

cd "$repo"
rm -rf .git
git init -q -b "$branch"
git config user.name  "unison-apt CI"
git config user.email "Linux571@gmail.com"

# Published debs are binaries; keep git from mangling them or guessing text.
printf '* -text -diff\n' > .gitattributes
# Pages serves the tree verbatim; this stops Jekyll from hiding files whose
# names begin with an underscore or being run at all.
: > .nojekyll

git add -A
git commit -q -m "$message"
git push -q --force "$remote" "$branch:$branch"
echo "published $(git rev-parse --short HEAD) to $branch"
```

**The `.nojekyll` file is load-bearing on GitHub Pages.** Without it Pages runs Jekyll over the tree, which can drop or rewrite files and will happily mangle an apt repository.

- [ ] **Step 6: Run the tests**

Run: `sh tests/run-tests.sh`
Expected: `test-version.sh`, `test-detect.sh`, `test-matrix.sh` all pass; `test-dpkg-order.sh` skips on macOS.

- [ ] **Step 7: Commit**

```bash
shellcheck -s sh scripts/detect.sh scripts/matrix.sh scripts/publish.sh tests/test-detect.sh tests/test-matrix.sh
git add -A
git commit -m "feat: version detection, dynamic matrix, and orphan-commit publishing

detect.sh reads the release feed from a file when UNISON_RELEASE_JSON is set, so
its logic is tested offline against fixtures rather than against GitHub's uptime.
publish.sh re-inits git in the tree, which makes the single-commit orphan branch
fall out for free. The .nojekyll it writes is not optional: Pages otherwise runs
Jekyll over the repository and rewrites it."
git push gitea main
```

---

## Task 9: Wire the whole pipeline together

**Files:**
- Modify: `.github/workflows/release.yml` (final form)
- Create: `README.md`

**Interfaces:**
- Consumes: every script from Tasks 1–8.
- Produces: a workflow that runs end to end, and a README a stranger can follow.

- [ ] **Step 1: Write the final workflow**

`.github/workflows/release.yml`:

```yaml
# One workflow, both platforms. Gitea runs .github/workflows/ when no .gitea/
# directory exists, so the dry run on Gitea exercises this exact file. Platform
# differences ride on the BUILD_ARCHES variable, never on `if:` checks against
# the platform.
name: release

on:
  schedule:
    - cron: '17 5 * * *'
  workflow_dispatch:
    inputs:
      force:
        description: build even if the version is unchanged
        type: boolean
        default: false
      version:
        description: upstream version override (empty = latest release)
        type: string
        default: ''
      publish:
        description: publish the result (off for dry runs)
        type: boolean
        default: true

jobs:
  detect:
    runs-on: ubuntu-latest
    container: debian:trixie
    outputs:
      changed:  ${{ steps.d.outputs.changed }}
      upstream: ${{ steps.d.outputs.upstream }}
      target:   ${{ steps.d.outputs.target }}
      matrix:   ${{ steps.m.outputs.matrix }}
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates curl
          # Jobs running in a container see a checkout owned by another uid, and
          # git then refuses to operate on it ("dubious ownership"). checkout@v4
          # handles its own calls; our later `git fetch`/`git show` need this.
          git config --global --add safe.directory "$GITHUB_WORKSPACE"

      - uses: actions/checkout@v4

      - name: Fetch the published state, if any
        run: |
          set -eu
          # The published branch may not exist yet; that is not an error.
          if git fetch --depth 1 origin "${{ vars.PUBLISH_BRANCH || 'apt-repo' }}" 2>/dev/null; then
            git show FETCH_HEAD:state.json > published-state.json || true
          fi
          ls -l published-state.json 2>/dev/null || echo "no published state yet"

      - id: d
        name: Detect
        run: |
          set -eu
          args="--state published-state.json"
          [ "${{ inputs.force }}" = "true" ] && args="$args --force"
          [ -n "${{ inputs.version }}" ] && args="$args --version ${{ inputs.version }}"
          sh scripts/detect.sh $args | tee -a "$GITHUB_OUTPUT"

      - id: m
        name: Build the matrix
        run: |
          set -eu
          arches="${{ vars.BUILD_ARCHES || 'amd64 arm64' }}"
          echo "matrix=$(sh scripts/matrix.sh $arches)" >> "$GITHUB_OUTPUT"

  build:
    needs: detect
    if: needs.detect.outputs.changed == 'true'
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.detect.outputs.matrix) }}
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.image }}
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates

      - uses: actions/checkout@v4

      - name: Build
        run: sh scripts/build-debs.sh "${{ needs.detect.outputs.upstream }}" "${{ matrix.suite }}" "$PWD/out"

      - uses: actions/upload-artifact@v4
        with:
          name: debs-${{ matrix.suite }}-${{ matrix.arch }}
          path: out/*.deb

  repo:
    needs: [detect, build]
    runs-on: ubuntu-latest
    container: debian:trixie
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends \
            git ca-certificates dpkg-dev apt-utils gnupg curl
          git config --global --add safe.directory "$GITHUB_WORKSPACE"

      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          pattern: debs-*
          path: incoming

      - name: Carry forward the previous two versions
        run: |
          set -eu
          mkdir -p repo
          # Retention is simply which debs are in the pool, because the index
          # tools hold no state. Keep the newest 3 upstream versions per suite.
          if git fetch --depth 1 origin "${{ vars.PUBLISH_BRANCH || 'apt-repo' }}" 2>/dev/null; then
            git archive FETCH_HEAD | tar -x -C repo || true
            rm -rf repo/dists   # rebuilt from scratch every run
            echo "carried forward:"
            find repo/pool -name '*.deb' 2>/dev/null | sort || true
          else
            echo "no published branch yet; starting from an empty pool"
          fi

      - name: Add the new debs to the pool
        run: |
          set -eux
          for d in incoming/debs-*; do
            suite="$(basename "$d" | cut -d- -f2)"
            mkdir -p "repo/pool/$suite/main/u/unison"
            cp "$d"/*.deb "repo/pool/$suite/main/u/unison/"
          done

      - name: Prune to 3 upstream versions per suite
        run: |
          set -eu
          for suite in $(sh -c '. scripts/lib.sh; suite_list'); do
            dir="repo/pool/$suite/main/u/unison"
            [ -d "$dir" ] || continue
            # Distinct upstream versions present, newest first.
            keep="$(ls "$dir" | sed -n 's/^unison_\([0-9][^-]*\)-.*/\1/p' \
                    | sort -Vru | head -3)"
            echo "$suite keeping: $(echo "$keep" | tr '\n' ' ')"
            for f in "$dir"/unison_*.deb "$dir"/unison-gtk_*.deb; do
              [ -e "$f" ] || continue
              v="$(basename "$f" | sed -n 's/^unison[a-z-]*_\([0-9][^-]*\)-.*/\1/p')"
              if ! printf '%s\n' "$keep" | grep -qx "$v"; then
                echo "pruning $f"; rm -f "$f"
              fi
            done
          done

      - name: Build the keyring packages and the bootstrap tree
        run: |
          set -eux
          for suite in $(sh -c '. scripts/lib.sh; suite_list'); do
            mkdir -p "repo/bootstrap/$suite" "repo/pool/$suite/main/u/unison"
            sh scripts/make-keyring-deb.sh "$suite" packaging/keys/unison-apt.asc "repo/bootstrap/$suite"
            cp "repo/bootstrap/$suite"/*.deb "repo/pool/$suite/main/u/unison/"
          done
          cp packaging/keys/unison-apt.asc repo/unison-apt.asc

      - name: Import the signing key
        env:
          APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
        run: |
          set -eu
          printf '%s' "$APT_SIGNING_KEY" | gpg --batch --import
          gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}' > keyid.txt

      - name: Assemble and sign
        run: sh scripts/make-repo.sh "$PWD/repo" "$(cat keyid.txt)" ${{ vars.BUILD_ARCHES || 'amd64 arm64' }}

      - name: Record the state and write the landing page
        run: |
          set -eu
          cat > repo/state.json <<EOF
          {
            "upstream": "${{ needs.detect.outputs.upstream }}",
            "pkgrev": "$(cat packaging/revision)",
            "target": "${{ needs.detect.outputs.target }}",
            "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          }
          EOF
          sh scripts/make-index.sh repo > repo/index.html

      - uses: actions/upload-artifact@v4
        with:
          name: repo
          path: repo

  install-test:
    needs: [detect, repo]
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.detect.outputs.matrix) }}
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.image }}
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates

      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: repo
          path: repo

      - name: Install from the repository and sync for real
        run: |
          set -eu
          pkgrev="$(cat packaging/revision)"
          version="$(sh -c ". scripts/lib.sh; deb_version '${{ needs.detect.outputs.upstream }}' '$pkgrev' '${{ matrix.suite }}'")"
          previous="$(sh scripts/previous-version.sh repo "${{ matrix.suite }}" "$version")"
          sh scripts/install-test.sh "$PWD/repo" "${{ matrix.suite }}" "$version" "$previous"

  publish:
    needs: [detect, install-test]
    if: inputs.publish != false
    runs-on: ubuntu-latest
    container: debian:trixie
    steps:
      - name: Tools
        run: |
          set -eux
          apt-get update
          apt-get install -y --no-install-recommends git ca-certificates

      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: repo
          path: repo

      - name: Publish
        env:
          TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -eu
          remote="$(git remote get-url origin | sed "s#https://#https://x-access-token:$TOKEN@#")"
          sh scripts/publish.sh "$PWD/repo" "$remote" \
            "${{ vars.PUBLISH_BRANCH || 'apt-repo' }}" \
            "unison ${{ needs.detect.outputs.target }}"
```

- [ ] **Step 2: Write the two small helpers the workflow calls**

`scripts/previous-version.sh`:

```sh
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

ls "$dir" 2>/dev/null \
  | sed -n 's/^unison_\(.*\)_[a-z0-9]*\.deb$/\1/p' \
  | grep -vFx "$current" \
  | sort -Vr \
  | head -1
```

`scripts/make-index.sh`:

```sh
#!/bin/sh
# Emit the landing page served at the repository root.
# usage: make-index.sh <repo-dir>
set -eu
cd "$(dirname "$0")/.."
. scripts/lib.sh
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
curl -fsSLO $REPO_URL/bootstrap/\$VERSION_CODENAME/${KEYRING_PKG}.deb
sudo dpkg -i ${KEYRING_PKG}.deb
sudo apt update
sudo apt install unison unison-gtk</code></pre>
<p>Unison requires the <em>same version at both ends</em> of a synchronization,
so add this repository on every host you sync between.</p>
<p><a href="unison-apt.asc">Signing key</a> · <a href="state.json">state.json</a></p>
</html>
EOF
```

**The keyring needs a version-free filename.** Its real name embeds a version
(`unison-apt-keyring_1~deb13_all.deb`), which no documented one-liner can predict.
So the workflow's "Build the keyring packages" step must also publish a stable
alias — add this line to that step, inside the suite loop:

```yaml
            cp "repo/bootstrap/$suite"/${KEYRING_PKG}_*_all.deb \
               "repo/bootstrap/$suite/${KEYRING_PKG}.deb"
```

That is what makes the install instructions above, and in the README, correct.
The versioned copy stays too: it is the one that goes into the pool, so apt can
upgrade the keyring later.

- [ ] **Step 4: Write the README**

`README.md`:

```markdown
# unison-apt

An apt repository carrying the current upstream release of
[Unison](https://github.com/bcpierce00/unison), built **with
`unison-fsmonitor`** — the binary Debian and Ubuntu leave out of their `unison`
package, without which `unison -repeat watch` cannot work and continuous
synchronization degrades to polling.

Suites: Debian trixie, Ubuntu 26.04 (resolute). Architectures: amd64, arm64.

## Install

```sh
. /etc/os-release
curl -fsSLO https://porelli.github.io/unison-apt/bootstrap/$VERSION_CODENAME/unison-apt-keyring.deb
sudo dpkg -i unison-apt-keyring.deb
sudo apt update && sudo apt install unison unison-gtk
```

`unison-gtk` is optional and is the only package that pulls in GTK.

The packages are named `unison` and `unison-gtk` deliberately: they replace the
distribution's own, so `apt upgrade` moves you onto the current release with no
further action. That also means **this repository takes over those two package
names** on any host where you add it.

## Why the version matters

Unison refuses to synchronize between mismatched versions. That is the reason
this repository exists — a fleet spanning distro releases cannot sync until
every host runs one version, and the distributions will never make that true.
It is also why the previous two versions are kept installable:

```sh
apt-cache madison unison
sudo apt install unison=2.54.0-1+porelli1~deb13
```

## How it works

A daily workflow checks upstream for a new release, builds packages inside a
container of each target suite, assembles a signed apt repository, installs from
it in a fresh container and runs a real `-repeat watch` sync to prove
`unison-fsmonitor` works, then publishes to the `apt-repo` branch, which GitHub
Pages serves.

- Design: `docs/superpowers/specs/2026-09-16-unison-apt-design.md`
- Key handling and rotation: `docs/key-management.md`
- Adding a suite: add a line to `packaging/suites.tsv`.
- Rebuilding at an unchanged upstream version: bump `packaging/revision`.
```

- [ ] **Step 5: Run the full pipeline on Gitea, without publishing**

```bash
tea repos edit --login claude --repo claude/unison-apt  # ensure BUILD_ARCHES=amd64 is set as a variable
```

Set the variable via the web UI (Settings → Actions → Variables): `BUILD_ARCHES` = `amd64`.

```bash
shellcheck -s sh scripts/*.sh tests/*.sh
sh tests/run-tests.sh
git add -A
git commit -m "feat: wire the full release pipeline"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt release -f publish=false
```

Expected: `detect` → `changed=true`, four jobs (2 suites × amd64 for build and install-test), every install test passing, `publish` skipped.

- [ ] **Step 6: Run it again with publishing on, then a third time to test the no-op path**

```bash
tea workflow run --login claude --repo claude/unison-apt release
```

Expected: the `apt-repo` branch appears with exactly one commit.

```bash
tea workflow run --login claude --repo claude/unison-apt release
```

Expected: `detect` reports `changed=false` and every other job skips. This is
the behaviour that keeps 360 days a year free.

- [ ] **Step 7: Verify retention with a forced second version**

```bash
tea workflow run --login claude --repo claude/unison-apt release -f version=2.53.7
```

Substitute a real older upstream tag. Then run again at 2.54.0 and confirm the
install test's retention check actually exercises a previous version rather than
printing `skip`.

- [ ] **Step 8: Commit**

Only if steps 5–7 required changes.

```bash
git add -A
git commit -m "fix: <the actual cause>"
git push gitea main
```

---

## Task 10: Prove the arm64 path

Only attempt this if Task 2 found nested docker available. Otherwise skip it and
say so — arm64's first real build is then on GitHub's native runner in Task 11,
which is an acceptable outcome, not a silent gap.

**Files:**
- Create: `.github/workflows/qemu-arm64.yml` (kept; it is useful whenever a
  native arm64 runner is unavailable)

**Interfaces:**
- Consumes: `scripts/build-debs.sh`, unchanged. That the same script runs under
  emulation without modification is the point.

**Deviation from the spec, deliberate.** The spec calls for a `qemu_arm64`
dispatch input on the release workflow. This plan uses a separate workflow file
instead, because the two paths cannot share a container mechanism: a native build
uses job-level `container:`, which takes no `--platform`, while an emulated build
must invoke `docker run --platform linux/arm64` itself. Folding that into
`release.yml` would mean a second build job differing in how it starts a
container — more divergence inside the file that is supposed to be identical
across platforms, not less. A separate file keeps `release.yml` uniform and makes
the emulated path obviously optional.

- [ ] **Step 1: Write the workflow**

```yaml
# Builds one suite for arm64 under emulation, for runners without a native arm64
# host. Slow by design; trixie only, so an emulation failure is not confounded
# with resolute's untested OCaml 5.4.
name: qemu-arm64
on:
  workflow_dispatch:
    inputs:
      version:
        description: upstream version to build
        type: string
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Register arm64 binfmt handlers
        run: docker run --privileged --rm tonistiigi/binfmt --install arm64

      - name: Build trixie/arm64 under emulation
        run: |
          set -eux
          docker run --rm --platform linux/arm64 \
            -v "$PWD:/w" -w /w debian:trixie \
            sh -c 'apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && sh scripts/build-debs.sh "${{ inputs.version }}" trixie /w/out'

      - uses: actions/upload-artifact@v4
        with:
          name: debs-trixie-arm64
          path: out/*.deb
```

- [ ] **Step 2: Run it and expect it to be slow**

```bash
git add .github/workflows/qemu-arm64.yml
git commit -m "ci: emulated arm64 build for runners without a native arm64 host"
git push gitea main
tea workflow run --login claude --repo claude/unison-apt qemu-arm64 -f version=2.54.0
```

Expected: green, eventually. An OCaml build under QEMU can take well over half
an hour. If it fails on emulation specifics rather than on the build itself,
record that and move on — Task 11 builds arm64 natively.

- [ ] **Step 3: Confirm the arm64 debs are genuinely arm64**

```bash
# after downloading the artifact
dpkg-deb -f unison_*_arm64.deb Architecture   # must print arm64
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "ci: verify the arm64 build path under emulation"
git push gitea main
```

---

## Task 11: Cut over to GitHub

**Files:**
- Modify: `README.md` if any URL changed.

**Interfaces:**
- Consumes: a green end-to-end run on Gitea.
- Produces: a live repository at `https://porelli.github.io/unison-apt`.

- [ ] **Step 1: Create the public repository and push**

```bash
gh repo create porelli/unison-apt --public \
  --description "apt repository for the current Unison release, with unison-fsmonitor"
git remote add github https://github.com/porelli/unison-apt.git
git push -u github main
```

Public is required, not stylistic: it is what makes Pages and the native arm64
runners free.

- [ ] **Step 2: Add the signing secret**

```bash
gh secret set APT_SIGNING_KEY --repo porelli/unison-apt < /path/to/unison-apt-secret.asc
```

If the private key was already deleted from disk (as Task 5 instructed), export
it again from your GnuPG keyring:

```bash
gpg --armor --export-secret-keys "$KEYID" | gh secret set APT_SIGNING_KEY --repo porelli/unison-apt
```

- [ ] **Step 3: Confirm workflow permissions allow pushing a branch**

The `publish` job pushes with `GITHUB_TOKEN`. In repo Settings → Actions →
General → Workflow permissions, select **Read and write permissions**. Without
this the push fails with a 403 at the very last step of an otherwise green run.

Leave `BUILD_ARCHES` unset on GitHub so it defaults to `amd64 arm64`.

- [ ] **Step 4: Dispatch once, with publishing on**

```bash
gh workflow run release --repo porelli/unison-apt
gh run watch --repo porelli/unison-apt
```

Expected: 8 jobs (2 suites × 2 arches, for build and install-test), then
`publish`, then an `apt-repo` branch with one commit. This is also the **first
native arm64 build**, so watch those two jobs specifically.

- [ ] **Step 5: Enable Pages**

Settings → Pages → Source: **Deploy from a branch**, Branch: `apt-repo`, Folder:
`/ (root)`. Wait for the first deployment, then confirm from outside CI:

```bash
curl -fsS https://porelli.github.io/unison-apt/state.json
curl -fsS https://porelli.github.io/unison-apt/dists/trixie/InRelease | head -20
```

- [ ] **Step 6: Install on a real host, from the real URL**

This is deliberately separate from the CI install test: CI serves the tree over
localhost, while Pages adds its own caching, MIME handling, and TLS.

On a trixie or resolute machine (a container on a Linux host is fine):

```sh
. /etc/os-release
curl -fsSLO https://porelli.github.io/unison-apt/bootstrap/$VERSION_CODENAME/unison-apt-keyring.deb
sudo dpkg -i unison-apt-keyring.deb
sudo apt update
sudo apt install unison
unison -version
unison-fsmonitor -version
```

Then the check that matters:

```sh
mkdir -p /tmp/a /tmp/b && echo hello > /tmp/a/one
UNISON=/tmp/ustate unison /tmp/a /tmp/b -ui text -batch -auto -repeat watch &
sleep 5
echo world > /tmp/a/two
sleep 5
cat /tmp/b/two   # must print: world
```

- [ ] **Step 7: Confirm the schedule is live and the no-op path is cheap**

Scheduled workflows only run from the default branch. Confirm `main` is default,
then check after the next scheduled run that `detect` reported
`changed=false` and everything else skipped.

- [ ] **Step 8: Commit and tidy**

```bash
git add -A
git commit -m "docs: record the live repository URL and cutover steps"
git push github main
git push gitea main
```

Keep the Gitea remote. It is where the next change gets tested.

---

## Notes for whoever executes this

**On local iteration.** Container-based iteration on this Mac is currently
unavailable: there is no Docker Desktop, and podman's VM fails to start
(`krunkit was terminated by signal: abort trap` — the machine is ten months old
and predates this OS version). Every build therefore runs on CI, which is why
Task 2 comes before Task 3: get a working CI loop before writing the packaging
that needs iterating on. If you want a local loop, `podman machine init
--provider applehv unison-test` creates a second machine without touching the
existing one — worth doing if Task 3 needs more than a few iterations, since the
Gitea runner also hosts production.

**On `shellcheck`.** It is installed locally. Run it on every script before
pushing; a `bashism` that works on GitHub's runner can fail in a Debian
container, where `/bin/sh` is dash.

**On failing loudly.** Several checks in this plan exist because their failure
mode is silence: a missing `--multiversion`, an armoured keyring, an empty
`manpage` target, `apt-ftparchive` checksumming its own output. If you are
tempted to remove one because it seems redundant, check the spec's risk list
first — it probably names the failure.
