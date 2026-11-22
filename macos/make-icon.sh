#!/bin/sh
# Makes the AppIcon set of the Mac app (Sources/ZSlice/Assets.xcassets)
# from the icon of zslice (../assets/icon). The art sits on the grid of
# the macOS icons: 824 of 1024 px, with a margin of 100 px, so it has the
# size of the other icons in the Dock. See "The grid of macOS app icons"
# in docs/references/formats-and-protocols.md. The 16 pt icons and the
# 32 pt icon at 1x come from zslice-small.svg, with thicker lines.
# make-app.sh makes the .icns of the set. Needs rsvg-convert. Run it
# after a change of the icon, and commit the files that it writes.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")"
set_dir=Sources/ZSlice/Assets.xcassets/AppIcon.appiconset
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$set_dir"
# An SVG of the art on the grid: the body of the source in a group that
# scales it to 824/1024 of the canvas, 100/1024 from each edge.
grid() {
    v=$1
    m=$(echo "$v * 100 / 1024" | bc -l)
    k=$(echo "824 / 1024" | bc -l)
    awk -v m="$m" -v k="$k" '
        /<svg/ && !done { print; print "<g transform=\"translate(" m " " m ") scale(" k ")\">"; done = 1; next }
        /<\/svg>/ { print "</g>"; print; next }
        { print }' "$2" > "$3"
}
grid 1024 ../assets/icon/zslice.svg "$tmp/big.svg"
grid 32 ../assets/icon/zslice-small.svg "$tmp/small.svg"
png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$set_dir/$3"; }
for pt in 16 32 128 256 512; do
    src="$tmp/big.svg"
    [ "$pt" -le 32 ] && src="$tmp/small.svg"
    png "$src" "$pt" "icon_${pt}x${pt}.png"
    # At 2x, 16 pt is 32 px: the small art still; 32 pt is 64 px: the big.
    src2="$tmp/big.svg"
    [ "$pt" -le 16 ] && src2="$tmp/small.svg"
    png "$src2" $((pt * 2)) "icon_${pt}x${pt}@2x.png"
done
{
    echo '{'
    echo '  "images" : ['
    first=1
    for pt in 16 32 128 256 512; do
        for s in 1 2; do
            f="icon_${pt}x${pt}.png"
            [ "$s" = 2 ] && f="icon_${pt}x${pt}@2x.png"
            [ "$first" = 1 ] || echo '    ,'
            first=0
            printf '    { "filename" : "%s", "idiom" : "mac", "scale" : "%sx", "size" : "%sx%s" }\n' "$f" "$s" "$pt" "$pt"
        done
    done
    echo '  ],'
    echo '  "info" : { "author" : "xcode", "version" : 1 }'
    echo '}'
} > "$set_dir/Contents.json"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > Sources/ZSlice/Assets.xcassets/Contents.json
echo "$set_dir"
