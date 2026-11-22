#!/bin/sh
# Makes the icon files of all apps from assets/icon/*.svg. Needs
# rsvg-convert and ImageMagick (magick). Run it after a change of the icon,
# and commit the files that it writes.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
big=assets/icon/zslice.svg
small=assets/icon/zslice-small.svg
out=assets/icon/out
mkdir -p "$out" web/app linux/data/icons/hicolor/scalable/apps
png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }
# Web: the favicon, the touch icon, and the icons of the manifest.
cp "$small" web/app/icon.svg
png "$small" 16 "$out/16.png"; png "$small" 32 "$out/32.png"; png "$small" 48 "$out/48.png"
magick "$out/16.png" "$out/32.png" "$out/48.png" web/app/favicon.ico
png "$big" 180 web/app/apple-touch-icon.png
png "$big" 192 web/app/icon-192.png
png "$big" 512 web/app/icon-512.png
# Linux: the hicolor theme.
cp "$big" linux/data/icons/hicolor/scalable/apps/org.beetlebug.Zslice.svg
for s in 16 24 32 48; do
  mkdir -p "linux/data/icons/hicolor/${s}x${s}/apps"
  png "$small" "$s" "linux/data/icons/hicolor/${s}x${s}/apps/org.beetlebug.Zslice.png"
done
for s in 64 128 256 512; do
  mkdir -p "linux/data/icons/hicolor/${s}x${s}/apps"
  png "$big" "$s" "linux/data/icons/hicolor/${s}x${s}/apps/org.beetlebug.Zslice.png"
done
# macOS: the 1024 px master. macos/make-icon.sh makes the AppIcon set.
png "$big" 1024 "$out/macos-1024.png"
# Windows: a .ico with 16 to 256 px.
for s in 64 128 256; do png "$big" "$s" "$out/$s.png"; done
png "$small" 24 "$out/24.png"
magick "$out/16.png" "$out/24.png" "$out/32.png" "$out/48.png" "$out/64.png" "$out/128.png" "$out/256.png" "$out/zslice.ico"
# Keep only the files that the apps use.
find "$out" -name '*.png' ! -name macos-1024.png -delete
