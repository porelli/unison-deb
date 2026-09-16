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
  # shellcheck disable=SC2064  # we want $tmprel to expand now, not at signal time
  trap "rm -f $tmprel" EXIT
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

# shellcheck disable=SC2086  # $arches must word-split into separate arguments
sh "$root/tests/test-repo-layout.sh" "$repo" $arches
