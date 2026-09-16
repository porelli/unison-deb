#!/bin/sh
# Turn a populated pool into signed apt metadata.
# usage: make-repo.sh <repo-dir> <keyid> <arch> [arch...]
#
# Expects <repo-dir>/pool/<suite>/main/u/<src>/*.deb to already exist.
set -eu
cd "$(dirname "$0")/.."
root="$(pwd)"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=/dev/null
. packaging/repo.conf

repo="${1:?repo dir required}"; shift
keyid="${1:?gpg key id required}"; shift
arches="$*"
[ -n "$arches" ] || { echo "at least one architecture required" >&2; exit 1; }

repo="$(cd "$repo" && pwd)"

# Track temp files so they all get cleaned up on exit
tmpfiles=""
# shellcheck disable=SC2154  # f is a loop variable inside the trap command string
trap 'for f in $tmpfiles; do rm -f "$f"; done' EXIT

for suite in $(suite_list); do
  [ -d "$repo/pool/$suite" ] || { echo "no pool for $suite, skipping" >&2; continue; }

  for arch in $arches; do
    mkdir -p "$repo/dists/$suite/main/binary-$arch"
    # This pipeline uses dpkg-scanpackages + apt-ftparchive, not reprepro, because
    # reprepro holds at most one version of a package per suite. Retaining 3 versions
    # (needed because Unison refuses to sync between mismatched versions, so a fleet
    # upgrading host-by-host requires previous versions to remain installable) is
    # irreconcilable with reprepro's data model. The stateless pipeline below indexes
    # all versions in the pool; --multiversion keeps older versions reachable instead
    # of indexing only the newest. --arch matches *_all.deb and *_<arch>.deb, which is
    # how the arch:all keyring package lands in every per-arch index.
    ( cd "$repo" && dpkg-scanpackages --multiversion --arch "$arch" "pool/$suite" ) \
      > "$repo/dists/$suite/main/binary-$arch/Packages"
    gzip -9nkf "$repo/dists/$suite/main/binary-$arch/Packages"
  done

  # apt-ftparchive checksums everything under the directory it is given, so the
  # output must not be written there while it runs.
  tmprel="$(mktemp)"
  tmpfiles="$tmpfiles $tmprel"
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

  # Verify the InRelease was signed by the published key, not just any key in the keyring
  if ! gpg --batch --verify --keyring "$root/packaging/keys/unison-deb.asc" "$repo/dists/$suite/InRelease" 2>&1 | grep -q "Good signature"; then
    echo "ERROR: $suite InRelease not verifiable against published key" >&2
    exit 1
  fi
  echo "verified: $suite InRelease is signed by the published key"
done

sh "$root/tests/test-repo-layout.sh" "$repo"
