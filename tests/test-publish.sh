#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
. tests/assert.sh

# Save the project root
root="$(pwd)"

# Create a temporary working directory
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Initialize a bare repo to push to
bare="$tmpdir/bare.git"
git init -q --bare "$bare"

# First publish: create a small repository tree
tree1="$tmpdir/tree1"
mkdir -p "$tree1/dists/stable"
printf 'Package: foo\nVersion: 1.0\n' > "$tree1/dists/stable/Packages"
printf 'data1\n' > "$tree1/README.md"
mkdir -p "$tree1/pool"
printf 'binary1\n' > "$tree1/pool/_private.deb"

sh "$root/scripts/publish.sh" "$tree1" "$bare" "apt-repo" "First publish"

# Clone the branch to inspect it
clone="$tmpdir/clone"
git clone -q -b apt-repo "$bare" "$clone"

# Verify first publish
cd "$clone"
assert_eq "$(git rev-list --count HEAD)" "1" "exactly one commit after first publish"
[ -f .nojekyll ] || { printf 'FAIL .nojekyll missing\n'; FAILED=1; }
[ -f .gitattributes ] || { printf 'FAIL .gitattributes missing\n'; FAILED=1; }
[ -f README.md ] || { printf 'FAIL README.md missing\n'; FAILED=1; }
[ -f dists/stable/Packages ] || { printf 'FAIL Packages missing\n'; FAILED=1; }
[ -f pool/_private.deb ] || { printf 'FAIL _private.deb missing (Jekyll-unsafe name)\n'; FAILED=1; }
assert_eq "$(cat README.md)" "data1" "first content present"
printf 'ok   first publish: one commit, all files present including Jekyll-unsafe names\n'

cd "$tmpdir"

# Second publish: different content
tree2="$tmpdir/tree2"
mkdir -p "$tree2/dists/stable"
printf 'Package: bar\nVersion: 2.0\n' > "$tree2/dists/stable/Packages"
printf 'data2\n' > "$tree2/NEWS.md"

sh "$root/scripts/publish.sh" "$tree2" "$bare" "apt-repo" "Second publish"

# Update the clone (force-push means we need to reset, not merge)
cd "$clone"
git fetch -q origin apt-repo
git reset -q --hard origin/apt-repo

# Verify second publish
assert_eq "$(git rev-list --count HEAD)" "1" "still exactly one commit after second publish"
[ -f .nojekyll ] || { printf 'FAIL .nojekyll missing after second publish\n'; FAILED=1; }
[ -f .gitattributes ] || { printf 'FAIL .gitattributes missing after second publish\n'; FAILED=1; }
[ -f NEWS.md ] || { printf 'FAIL NEWS.md missing\n'; FAILED=1; }
[ ! -f README.md ] || { printf 'FAIL README.md still present (should be replaced)\n'; FAILED=1; }
assert_eq "$(cat NEWS.md)" "data2" "second content present"
assert_eq "$(cat dists/stable/Packages | head -1)" "Package: bar" "second publish replaced the tree"
printf 'ok   second publish: still one commit, content replaced\n'

exit "$FAILED"
