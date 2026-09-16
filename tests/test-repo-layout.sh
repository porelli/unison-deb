#!/bin/sh
# usage: test-repo-layout.sh <repo-dir>
# Reads the canonical architecture list from repo.conf, not from arguments.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=/dev/null
. packaging/repo.conf

repo="${1:?repo dir required}"
# shellcheck disable=SC2153  # ARCHES is set in repo.conf which is sourced above
arches="$ARCHES"
[ -n "$arches" ] || { echo "ARCHES not set in repo.conf" >&2; exit 1; }

# Track package sets per suite to verify consistency
trixie_pkgset=""
resolute_pkgset=""

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
    # Match whole lines to avoid false positives from substrings (e.g. "unison" matching "unison-deb-keyring")
    if ! printf '%s\n' "$body" | grep -qx 'Package: unison'; then
      printf 'FAIL %s/%s does not index unison\n' "$suite" "$arch"; FAILED=1
    else
      printf 'ok   %s/%s indexes unison\n' "$suite" "$arch"
    fi
    if ! printf '%s\n' "$body" | grep -qx 'Package: unison-gtk'; then
      printf 'FAIL %s/%s does not index unison-gtk\n' "$suite" "$arch"; FAILED=1
    else
      printf 'ok   %s/%s indexes unison-gtk\n' "$suite" "$arch"
    fi
    # The arch:all keyring package must appear in EVERY per-arch index.
    if ! printf '%s\n' "$body" | grep -qx "Package: $KEYRING_PKG"; then
      printf 'FAIL %s/%s does not index the keyring\n' "$suite" "$arch"; FAILED=1
    else
      printf 'ok   %s/%s indexes the keyring\n' "$suite" "$arch"
    fi

    # Filename paths must be relative to the repository root, or apt 404s.
    case "$body" in
      *"Filename: pool/$suite/main/"*) printf 'ok   %s/%s Filename is repo-relative\n' "$suite" "$arch" ;;
      *) printf 'FAIL %s/%s has no repo-relative Filename\n' "$suite" "$arch"; FAILED=1 ;;
    esac

    # No foreign architecture leaked in.
    foreign_found=0
    for other in $arches; do
      [ "$other" = "$arch" ] && continue
      case "$body" in
        *"Architecture: $other"*)
          printf 'FAIL %s/%s index contains %s packages\n' "$suite" "$arch" "$other"
          FAILED=1
          foreign_found=1
          ;;
      esac
    done
    [ "$foreign_found" -eq 0 ] && printf 'ok   %s/%s has no foreign architecture packages\n' "$suite" "$arch"

    # Check that exactly the three mandated packages are present, no more, no less.
    # Extract unique package names from this arch's index (first occurrence only).
    actual_pkgs="$(printf '%s\n' "$body" | awk '/^Package:/ && !seen[$2]++ {print $2}' | sort)"
    expected_pkgs="$(printf 'unison\nunison-deb-keyring\nunison-gtk\n' | sort)"
    if [ "$actual_pkgs" != "$expected_pkgs" ]; then
      printf 'FAIL %s/%s package set is not exactly unison, unison-gtk, %s\n' "$suite" "$arch" "$KEYRING_PKG"
      printf '     expected:\n%s\n' "$expected_pkgs"
      printf '     actual:\n%s\n' "$actual_pkgs"
      FAILED=1
    else
      printf 'ok   %s/%s has exactly the three mandated packages\n' "$suite" "$arch"
    fi

    # Track package set for cross-suite consistency check (use first arch's set)
    if [ "$arch" = "$(printf '%s' "$arches" | awk '{print $1}')" ]; then
      case "$suite" in
        trixie)   trixie_pkgset="$actual_pkgs" ;;
        resolute) resolute_pkgset="$actual_pkgs" ;;
      esac
    fi
  done
done

# Verify that both suites ship the same package set
if [ -n "$trixie_pkgset" ] && [ -n "$resolute_pkgset" ]; then
  if [ "$trixie_pkgset" != "$resolute_pkgset" ]; then
    printf 'FAIL trixie and resolute package sets differ\n'
    printf '     trixie: %s\n' "$(printf '%s' "$trixie_pkgset" | tr '\n' ' ')"
    printf '     resolute: %s\n' "$(printf '%s' "$resolute_pkgset" | tr '\n' ' ')"
    FAILED=1
  else
    printf 'ok   trixie and resolute have the same package set\n'
  fi
fi

exit "$FAILED"
