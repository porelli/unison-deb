#!/bin/sh
# usage: test-repo-layout.sh <repo-dir> <arch> [more-arches...]
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=packaging/repo.conf
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
