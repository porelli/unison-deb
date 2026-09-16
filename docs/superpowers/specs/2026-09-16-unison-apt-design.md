# unison-apt: an apt repository for current Unison, with fsmonitor

Date: 2026-09-16
Status: approved, not yet implemented

## Problem

Debian and Ubuntu ship `unison`, but their package contains exactly one file
worth having:

```
/usr/bin/unison
/usr/share/doc/unison/changelog.gz
/usr/share/doc/unison/copyright
/usr/share/man/man1/unison.1.gz
```

There is no `unison-fsmonitor`. Without it, `unison -repeat watch` cannot work,
so continuous sync degrades to polling. Verified 2026-09-16 against Debian
bookworm, Debian trixie, and Ubuntu noble; all three are identical in this
respect.

The versions also lag: trixie ships `2.53+1`, Ubuntu resolute ships
`2.53+1build1`, while upstream is at 2.54.0 (released 2026-05-01). This matters
more than usual for Unison, because Unison requires the *same* version on both
ends of a sync. A fleet spanning distro releases cannot sync at all until every
host is on one version, and the distro will never be the thing that makes that
true.

Upstream's own Linux release tarballs *do* include `unison-fsmonitor`, and the
x86_64 one is statically linked. So the gap is not upstream — it is apt. But
upstream publishes no Linux arm64 binary at all, which is why this project
compiles rather than repackages.

## Goals

- `apt install unison` yields the current upstream release, with
  `unison-fsmonitor`, on Debian trixie and Ubuntu 26.04, amd64 and arm64.
- New upstream releases are picked up and published without human action.
- The GUI (`unison-gui`) is packaged too.
- The repo is GPG-signed, because apt refuses unsigned repos by default since
  Debian 11 / Ubuntu 22.04.
- The pipeline is verifiable on a self-hosted Gitea instance before GitHub runs
  it, and the thing verified there is the same artifact GitHub will run.

## Non-goals

- Suites beyond current stable. Only Debian trixie and Ubuntu 26.04 resolute.
  Adding Debian 14 later is a deliberate one-line matrix change, never automatic
  — see "Suite list is data, not detection".
- Architectures beyond amd64 and arm64. No i386, armhf, riscv64.
- Getting this into Debian proper. That would want full source packaging and
  sbuild; a personal repo does not.
- Windows and macOS. Upstream already publishes usable binaries for both.

## Decisions

Four decisions were settled before design, and each closes off alternatives
worth recording.

**Compile from source for both arches**, rather than repackaging upstream's
static tarball. Repackaging would be faster and toolchain-free, but upstream
publishes no Linux arm64 binary, so arm64 requires compiling regardless. One
recipe for both arches beats two codepaths.

**Per-suite dynamic builds**, rather than one musl-static binary per arch.
Static musl (upstream's own approach: `ocaml-option-musl` +
`ocaml-option-static` + `LDFLAGS=-static`) would let a single deb per arch serve
every distro, collapsing the matrix. It was rejected in favour of building
inside each target suite, so `dh_shlibdeps` derives that suite's real
dependencies instead of us asserting them, `lintian` has something honest to
check, and a libc or GTK security update reaches users through their own
distro's upgrade path rather than requiring a rebuild here. The cost is that the
matrix grows with every suite added, and each new Debian release is maintenance.

**GitHub Pages from a public repo**, rather than Gitea's native Debian registry.
Pages is free, HTTPS, and needs no infrastructure; a public repo also unlocks
free native arm64 runners, which removes QEMU from the GitHub side entirely.
Clients depend on GitHub's uptime rather than a self-hosted instance.

**Reuse the distro's package names** (`unison`, `unison-gtk`), rather than
coexisting via `update-alternatives` under versioned names. Because the names
match, no `Conflicts`/`Replaces`/`Provides` juggling is needed — installing is
an ordinary version upgrade, and `apt upgrade` moves hosts off the distro build
with no action from their owner. This also dissolves a hazard that the
coexistence approach would have to handle: the distro's `unison-gtk` depends on
`unison`, so replacing only `unison` would leave a 2.53 GUI beside a 2.54 CLI,
and a version-mismatched GUI cannot sync. Owning both names makes them move
together. The tradeoff accepted: this repo takes over two distro package names
on every host that adds it.

## Deliverables

Three binary packages per suite.

| Package | Arch | Contents |
|---|---|---|
| `unison` | amd64, arm64 | `/usr/bin/unison`, `/usr/bin/unison-fsmonitor`, `unison.1`, text manual, copyright, changelog |
| `unison-gtk` | amd64, arm64 | `/usr/bin/unison-gui`, `/usr/bin/unison-gtk` symlink, upstream's `.desktop` entry and icons, `unison-gui.1` |
| `unison-apt-keyring` | all | `/usr/share/keyrings/unison-apt.gpg`, `/etc/apt/sources.list.d/unison-apt.sources` |

`unison` declares `Provides: unison-fsmonitor` so the capability is
discoverable. `unison-gtk` declares `Depends: unison (= ${binary:Version})`,
which is what pins the GUI and CLI to one version.

The GUI binary ships under upstream's name (`unison-gui`) with a symlink at
Debian's (`unison-gtk`), so both upstream documentation and existing desktop
launchers are correct.

The desktop entry and icons are **upstream's own** — `data/unison-gui.desktop`
and `icons/U.{16,24,32,48,256}x*.png` plus `icons/U.svg`, which upstream's
`make install` places into `/usr/share/applications` and the hicolor icon theme.
Neither distro ships them, so this is a real gain over the distro package, but
it is upstream's work rather than ours and must not be reinvented.

`unison-gtk`'s man page is a one-line `.so man1/unison.1` redirect installed as
`unison-gui.1`, with a `unison-gtk.1` link. Upstream ships only one man page
source and the GUI takes the same options, so duplicating its content would just
create two things to keep in sync.

### Version scheme

```
2.54.0-1+porelli1~deb13     (Debian trixie)
2.54.0-1+porelli1~ub2604    (Ubuntu 26.04 resolute)
```

Four properties, each load-bearing:

- Beats trixie's `2.53+1-1` and resolute's `2.53+1build1`, so `apt upgrade`
  transitions hosts without pinning.
- Beats a hypothetical future Debian `2.54.0-1`, because in dpkg's ordering a
  revision of `1+porelli1~deb13` outranks a bare `1`. Without the `+porelli1`,
  a distro release of the same upstream version would tie.
- Orders correctly across a dist-upgrade: `~deb13` < `~deb14` and `~ub2604` <
  `~ub2804`, because the numeric runs compare numerically.
- `+porelli1` is this repo's packaging revision, held in `packaging/revision`.
  Bumping it rebuilds and republishes at an unchanged upstream version, which is
  required the first time a `debian/rules` fix has to reach users.

### Client install

```sh
. /etc/os-release
curl -fsSLO https://porelli.github.io/unison-apt/bootstrap/$VERSION_CODENAME/unison-apt-keyring.deb
sudo dpkg -i unison-apt-keyring.deb
sudo apt update && sudo apt install unison unison-gtk
```

The keyring package is fetched by `curl` rather than `apt`, because it is what
configures the repo apt would need. It is also published *into* the repo, so
later key rotation arrives as an ordinary upgrade.

`unison-apt-keyring` is `Architecture: all` but built once per suite, because
the `.sources` file it ships names a single suite and deb822 has no variable
substitution. Hence the codename in the bootstrap path.

## Build pipeline

One workflow, `.github/workflows/release.yml`.

Triggers: `schedule` (daily) and `workflow_dispatch` with inputs `force`
(rebuild at an unchanged version) and `version` (override the detected upstream
version).

### Detect job

Reads upstream's `releases/latest`. That endpoint excludes prereleases by
definition, so release candidates never ship — this is the only prerelease
guard, and it is deliberate rather than incidental.

Computes the target as `<upstream>+porelli<pkgrev>`, reading `pkgrev` from
`packaging/revision`, and compares it to `state.json` on the published
`apt-repo` branch. If unchanged and `force` is not set, every downstream job
skips. On the roughly 360 days a year with no upstream release, the workflow
costs one API call.

### Build matrix

Four jobs: `{trixie, resolute} × {amd64, arm64}`.

- amd64 on `runs-on: ubuntu-latest`; arm64 on `runs-on: ubuntu-24.04-arm`.
  Native arm64 runners are free for public repos, so **no QEMU on GitHub**.
- `container: debian:trixie` / `container: ubuntu:26.04`. Both images publish
  amd64 and arm64. The job runs inside the target suite; that is the entire
  point of the per-suite approach.
- Build deps: `build-essential debhelper ocaml-nox ocaml-findlib
  liblablgtk3-ocaml-dev pkg-config`.
- Source is upstream's tag tarball plus a vendored `debian/` directory in this
  repo. **Nothing is fetched from the network during the package build** — the
  tarball download is a workflow step, and `debian/rules` touches only the tree
  it is given.
- `dpkg-buildpackage -b -uc -us`. Upstream's `all:` target is
  `tui guimaybe macuimaybe fsmonitor`, and lablgtk3 presence is detected
  automatically, so both the GUI and fsmonitor are built without extra flags.
  `src/strings.ml` is checked into upstream's tree, so `make` needs no LaTeX.
- Documentation is generated from the tree, not lifted from upstream's binary
  release:
  - `man/unison.1` is produced by `make -C src manpagefile`, which expands
    `man/unison.1.in` using the freshly built binary's `-prefsman short|full`
    output. No LaTeX, HEVEA, or Lynx.
    **Trap:** the top-level `manpage` target — and `src/Makefile.OCaml`'s
    `manpage:` — are deliberately *empty* no-ops, as is `docs:`. `make` and
    `make manpage` therefore produce no man page at all, silently. Only
    `manpagefile` builds it.
  - The text manual is generated with `./src/unison -doc all`, which upstream
    documents as containing "exactly the same information as the printed and HTML
    manuals, modulo formatting" (the manual is embedded in the binary via
    `src/strings.ml`). The HTML and PDF manuals are not shipped; they are the
    only artifacts that would require the LaTeX toolchain.
- Installation stages through upstream's own `make install`, which honours
  `DESTDIR`, `PREFIX`, `BINDIR`, `MANDIR`, `INSTALL_PROGRAM`, and `INSTALL_DATA`.
  `debian/rules` stages into `debian/tmp` and lets per-package `.install` files
  split the result, rather than reimplementing the install logic.

### Build gates

Every build job must pass all of these, or it fails:

- `make test` (upstream's own unit tests).
- `unison` and `unison-fsmonitor` each execute and report a version.
- `unison-gui` resolves all its shared libraries (`ldd -r`, no missing symbols)
  and answers `-version`.
- `man/unison.1` exists and is non-empty — because `make` produces it silently
  never, and a missing man page is otherwise invisible until a user runs `man`.

`unison-fsmonitor` existing is the entire reason this project exists, so it is
asserted rather than assumed.

`unison-gui -version` is expected to work headlessly: `src/main.ml` handles
`-version` and exits before any GTK initialisation, and prints via
`gui_safe_printf`, which exists precisely so GUI builds can answer on stdout.
`ldd -r` is kept alongside it as the assertion that holds regardless. If
`-version` turns out to need a display, wrap it in `xvfb-run` rather than
dropping the check.

`lintian` runs advisory at first; promoting it to blocking is a later decision
made against real output.

## Repository generation and signing

`dpkg-scanpackages` plus `apt-ftparchive release` plus `gpg`. **Not `reprepro`**,
which an earlier draft of this spec specified and which cannot do the job:
reprepro's data model holds exactly one version of a package per distribution.
Its manpage has no field for retaining more, and its `older_version` ignore-option
exists precisely because feeding it an older version than the one it holds is an
error. That is irreconcilable with retaining old versions, below.

The pipeline is stateless — no database, nothing to persist or regenerate:

```sh
# per suite, per architecture
dpkg-scanpackages --multiversion --arch "$arch" "pool/$suite" \
  > "dists/$suite/main/binary-$arch/Packages"
gzip -9kf "dists/$suite/main/binary-$arch/Packages"
# per suite
apt-ftparchive release "dists/$suite" > "dists/$suite/Release"
gpg --clearsign  -o "dists/$suite/InRelease"   "dists/$suite/Release"
gpg --detach-sign -o "dists/$suite/Release.gpg" "dists/$suite/Release"
```

Two `dpkg-scanpackages` flags carry the whole design:

- **`--multiversion`** ("include all found packages in the output"). Without it,
  only the newest version of each package is indexed, and version retention
  silently fails — the debs would sit in the pool, unreachable.
- **`--arch <arch>`**, which matches the pattern `*_all.deb` and `*_<arch>.deb`.
  `Architecture: all` packages therefore land in *every* per-architecture index
  with no extra work, which is what makes `unison-apt-keyring` installable
  everywhere. This is the mechanism; there is no `binary-all/` directory and
  `all` is deliberately absent from the `Release` file's `Architectures`.

The pool is arranged per suite (`pool/<suite>/main/u/unison/…`) so a single
`dpkg-scanpackages` invocation naturally scopes to one suite.

Retention: the fresh debs plus older debs carried forward from the currently
published branch, keeping **3 upstream versions in total** — the one being
published plus the two preceding it. Because the tool is stateless, retention is
simply which files are in the pool.

Retaining old versions is not sentimentality. Unison requires matching versions
on both ends of a sync, so when 2.54.1 lands and a fleet upgrades host by host,
`apt install unison=2.54.0-1+porelli1~deb13` has to keep working or syncing
breaks mid-migration.

`Release` fields, set via `-o APT::FTPArchive::Release::*`: `Origin`, `Label`,
`Suite`, `Codename`, `Architectures: amd64 arm64`, `Components: main`. Both a
signed `InRelease` and a detached `Release.gpg` are published, the latter for
clients that still look for it.

### Signing key

One repo-only ed25519 key, **generated with no passphrase**, stored as the
`APT_SIGNING_KEY` secret (armoured private key). The public key is published at
`/unison-apt.asc` and shipped inside `unison-apt-keyring`.

Passphrase-less is a deliberate weakening, recorded here because it is easy to
mistake for an oversight.

Note that its **original justification no longer holds**. That justification was
that reprepro signs through gpgme, which ignores `--pinentry-mode loopback` and
`--passphrase-fd`, making a passphrase require `gpg-preset-passphrase` and
`allow-preset-passphrase` in CI. Since signing now invokes `gpg` directly, a
passphrase is trivially supportable and that obstacle is gone.

What remains is the weaker but standalone argument: the passphrase would live in
the same secret store as the key it protects, so it defends against essentially
nothing that compromising the store would not already defeat. The real controls
are the secret store and the key being useful for nothing but this repo.

This is therefore a judgment call rather than a constraint, and it is cheap to
reverse: add a second secret and a `--batch --pinentry-mode loopback
--passphrase-fd 3` to the two `gpg` calls.

If the key is ever compromised: generate a new one, publish an updated
`unison-apt-keyring` shipping both old and new public keys, wait for clients to
upgrade, then drop the old key and re-sign.

## Testing

Build gates (above) prove the binaries exist and run. They do not prove the
repository works, so a separate install test gates publication.

Per suite × arch, before anything is published:

1. Fresh container of that suite.
2. Serve the generated tree with `python3 -m http.server`.
3. `dpkg -i` the keyring package, `apt update`, `apt install unison unison-gtk`.
4. Assert `/usr/bin/unison-fsmonitor` is present and executable; installed
   version matches the expected version string; `apt-cache policy unison` shows
   this repo outranking the distro's.
5. Assert that installing `unison` alone pulls in no GTK packages, by installing
   it in a container without `unison-gtk` and checking the resolved dependency
   set. This is what keeps risk 3 from reaching headless servers.
6. Assert that a retained older version is installable — `apt-cache madison
   unison` lists more than one version, and `apt install unison=<previous>`
   succeeds. This is the only check that would catch a missing `--multiversion`,
   which otherwise fails silently. Skipped on the first ever run, when there is
   no previous version to retain.
7. **Run a real sync under `unison -repeat watch`** between two local
   directories: touch a file, confirm it propagates.

Step 7 is the test that proves the premise. Steps 1–6 confirm a file is on disk
and apt is willing to install it; only step 7 shows that fsmonitor does its job.

arm64 install tests run on the arm64 runner, natively.

## Publishing and platform parity

The generated tree is committed to an `apt-repo` branch as an **orphan commit,
force-pushed**. The branch is always exactly one commit, so years of releases
never accumulate in git history. Old package versions are retained by carrying
their debs forward into the new tree, not by git history.

GitHub Pages serves that branch at `/` using the classic branch source. There is
no `deploy-pages` step and no Pages artifact upload, and that is the design
choice that buys platform parity: the publish step is byte-identical on Gitea
and GitHub, so the only GitHub-specific element in the entire project is one
setting in the Pages web UI.

Published tree layout:

```
dists/trixie/main/binary-{amd64,arm64}/Packages{,.gz}
dists/trixie/{Release,Release.gpg,InRelease}
dists/resolute/...
pool/main/u/unison/*.deb
bootstrap/{trixie,resolute}/unison-apt-keyring.deb
unison-apt.asc
state.json
index.html
```

`state.json` is publicly readable at the Pages URL. It holds a version string;
there is nothing in it to protect.

### Suite list is data, not detection

The matrix names `trixie` and `resolute` explicitly rather than building against
`debian:stable` and `ubuntu:latest`. Tracking the `stable` tag would silently
retarget builds at a new glibc and GTK the day Debian 14 releases, while clients
kept requesting `trixie` — a changed ABI under an unchanged suite name. Naming
suites in a data-driven matrix keeps that a deliberate act.

## Gitea dry run, then GitHub cutover

Gitea runs `.github/workflows/` when no `.gitea/` directory exists. The same
single workflow file therefore drives both platforms, and the dry run exercises
the real artifact rather than a sibling of it. Platform differences ride on repo
variables, never `if:` branches on the platform.

**Probe first, before any build logic is written:** confirm that act_runner's
backend supports job-level `container:`. If it is a host or LXC backend rather
than docker, `container:` will not work and the per-suite build model needs
rethinking. This is a five-minute check and must not be discovered at hour three.

The matrix is driven by a repo variable `BUILD_ARCHES`, defaulting to
`amd64 arm64` and set to `amd64` on Gitea. Both suites build on both platforms;
only the architectures differ. That runner also hosts a production deployment
and reaches roughly 77% saturation during push bursts (recorded in
`sorted/app`'s CI comments), so four OCaml builds per run — two of them
QEMU-emulated — is not a neighbourly default.

A `dispatch` input `qemu_arm64` runs one additional arm64 build, **trixie only**,
under QEMU, so the arm64 path is proven once before GitHub ever sees it. Trixie
rather than resolute because resolute's OCaml 5.4 is the independent risk in
risk 1, and mixing an untested compiler with an emulated architecture would make
a failure hard to attribute.

Cutover, once the dry run is green:

1. Create the public GitHub repo `porelli/unison-apt`.
2. `git remote add github` and push `main`.
3. Add the `APT_SIGNING_KEY` secret.
4. Dispatch the workflow manually once; it creates the `apt-repo` branch.
5. Enable Pages with `apt-repo` as source, `/` as path.
6. Install from the real Pages URL on a live host, including the
   `-repeat watch` check.

Step 6 is separate from the CI install test on purpose: CI tests a locally
served tree, and Pages introduces its own caching and MIME behaviour.

## Risks

1. **Resolute's OCaml is 5.4; trixie's is 5.3.** Upstream CI tests 4.08, 4.12,
   4.14, and 5.x, but 5.4 is newer than anything it covers. The resolute build
   is the likeliest to break. It surfaces as a failed job, not a bad package,
   because publication is gated on all builds and install tests passing.
2. **Index generation has two silent-failure modes**, both invisible without a
   real apt client: omitting `--multiversion` indexes only the newest version, so
   retained debs sit in the pool unreachable; and a wrong `--arch` pattern drops
   `unison-apt-keyring` out of a per-architecture index, breaking the bootstrap
   for that architecture only. Neither produces an error. The install test
   against real apt is what catches them, which is why it gates publication.
3. **A GTK dependency chain resolved by `dh_shlibdeps`** could pull a large
   dependency set onto headless servers via `unison-gtk`. Mitigated by
   `unison-gtk` being a separate package nobody has to install; `unison` itself
   must stay GTK-free, which the install test should assert.
4. **Pages soft limits**: 1 GB site, 100 GB/month bandwidth. Three retained
   versions × 4 debs per suite is far under, but the ceiling exists and a
   popular repo would meet it.
5. **Static-free does not mean patch-free.** Per-suite dynamic linking means
   libc and GTK fixes arrive via the distro, but a Unison bug still requires
   upstream to release. This repo shortens that path; it does not remove it.

## Open items

- Whether `lintian` becomes a blocking gate, decided against real output after
  the first successful build.
- Whether to publish to Gitea's Debian registry as a permanent second source.
  Deliberately deferred: it would add a second publish path and break the
  byte-identical-workflow property that makes the dry run meaningful.
