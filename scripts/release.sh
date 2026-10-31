#!/bin/bash
# Build the versioned source tarball for a release.
#
#   scripts/release.sh            check consistency, write dist/dksh-VERSION.tar.gz, print the Zig hash
#
# The version comes from build.zig.zon. The tarball is made with `git archive`
# from HEAD (so it contains exactly what is committed, tests included) and is
# byte-for-byte reproducible for a given commit, which keeps the Zig content
# hash stable. It does not need the tag to exist yet.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)"
[ -n "$version" ] || { echo "cannot read the version from build.zig.zon" >&2; exit 1; }

fail=0
grep -q "^## $version\$" CHANGELOG.md || { echo "CHANGELOG.md has no '## $version' section" >&2; fail=1; }
grep -q "dksh $version" docs/dksh.1    || { echo "docs/dksh.1 .TH line does not say 'dksh $version'" >&2; fail=1; }
[ -z "$(git status --porcelain)" ]     || { echo "the working tree is not clean; commit first" >&2; fail=1; }
[ $fail = 0 ] || exit 1

mkdir -p dist
out="dist/dksh-$version.tar.gz"
git archive --format=tar --prefix="dksh-$version/" HEAD | gzip -n -9 > "$out"
echo "wrote $out ($(du -h "$out" | cut -f1)) from $(git rev-parse --short HEAD)"
sha256sum "$out"
echo "zig hash:"
zig fetch "$out"
