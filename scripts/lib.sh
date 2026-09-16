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
