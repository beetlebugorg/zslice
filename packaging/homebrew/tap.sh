#!/bin/sh
# Writes the Homebrew files of zslice for a version into a folder with the
# layout of the tap (beetlebugorg/homebrew-tap):
#
#   Formula/zslice.rb      the command line tool (macOS and Linux)
#   Formula/zslice-gtk.rb  the Linux app, built from the source
#   Casks/zslice.rb        the Mac app, from the signed dmg
#
# Usage: packaging/homebrew/tap.sh <version> <dist folder> <tap folder>
#
# The version is the tag with no v (0.6.0-beta). The dist folder has the
# files of the release. The script reads the SHA-256 of the CLI tarballs
# and of the dmg from them, and downloads the source tarball of the tag
# from GitHub for its SHA-256. With no signed dmg in the dist folder, the
# script does not write the cask. The release workflow runs the script.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

version=${1:?usage: tap.sh <version> <dist> <tap>}
dist=${2:?usage: tap.sh <version> <dist> <tap>}
tap=${3:?usage: tap.sh <version> <dist> <tap>}
repo=${GITHUB_REPOSITORY:-beetlebugorg/zslice}
here=$(dirname "$0")
releases="https://github.com/$repo/releases/download/v$version"

sha() { sha256sum "$1" | cut -d' ' -f1; }
cli() { sha "$dist/zslice-$version-$1.tar.gz"; }

mkdir -p "$tap/Formula" "$tap/Casks"

# The source tarball of GitHub for the tag.
src_url="https://github.com/$repo/archive/refs/tags/v$version.tar.gz"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$src_url" -o "$tmp"
src_sha=$(sha "$tmp")

sed -e "s|@VERSION@|$version|g" \
    -e "s|@RELEASES@|$releases|g" \
    -e "s|@SHA_AARCH64_MACOS@|$(cli aarch64-macos)|" \
    -e "s|@SHA_X86_64_MACOS@|$(cli x86_64-macos)|" \
    -e "s|@SHA_AARCH64_LINUX@|$(cli aarch64-linux-musl)|" \
    -e "s|@SHA_X86_64_LINUX@|$(cli x86_64-linux-musl)|" \
    "$here/zslice.rb.in" > "$tap/Formula/zslice.rb"

sed -e "s|@SRC_URL@|$src_url|" -e "s|@VERSION@|$version|" -e "s|@SHA@|$src_sha|" \
    "$here/zslice-gtk.rb.in" > "$tap/Formula/zslice-gtk.rb"

dmg="$dist/zslice-$version-macos-universal.dmg"
if [ -f "$dmg" ]; then
    sed -e "s|@VERSION@|$version|" -e "s|@SHA@|$(sha "$dmg")|" -e "s|@REPO@|$repo|" \
        "$here/zslice-cask.rb.in" > "$tap/Casks/zslice.rb"
else
    echo "tap.sh: no signed dmg in $dist: the cask stays as it is" >&2
fi
