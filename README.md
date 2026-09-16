# unison-deb

An apt repository carrying the current upstream release of
[Unison](https://github.com/bcpierce00/unison), built **with
`unison-fsmonitor`** — the binary Debian and Ubuntu leave out of their `unison`
package, without which `unison -repeat watch` cannot work and continuous
synchronization degrades to polling.

Suites: Debian trixie, Ubuntu 26.04 (resolute). Architectures: amd64, arm64.

## Install

```sh
. /etc/os-release
curl -fsSLO https://porelli.github.io/unison-deb/bootstrap/$VERSION_CODENAME/unison-deb-keyring.deb
sudo dpkg -i unison-deb-keyring.deb
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

The packaging targets the 2.54.0+ tree layout and will not build releases that
predate upstream shipping the desktop file and icons (i.e. versions < 2.54.0).

- Design: `docs/superpowers/specs/2026-09-16-unison-deb-design.md`
- Key handling and rotation: `docs/key-management.md`
- Adding a suite: add a line to `packaging/suites.tsv`.
- Rebuilding at an unchanged upstream version: bump `packaging/revision`.
