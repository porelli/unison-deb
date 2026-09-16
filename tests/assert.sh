# shellcheck shell=sh
# Sourced by tests/test-*.sh. Sets FAILED=1 on any failure.
# shellcheck disable=SC2034  # FAILED is checked by sourcing test scripts
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
