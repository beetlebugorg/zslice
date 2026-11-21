#!/bin/bash
# Builds the Mac app for a release: the Release configuration of the Xcode
# project (arm64 and x86_64), a Developer ID signature, the hardened
# runtime, notarization, and a stapled .dmg.
#
#   macos/release.sh <version> <build-number>
#
# The signature needs a "Developer ID Application" identity in an unlocked
# keychain. Notarization needs an App Store Connect API key:
#
#   APPLE_TEAM_ID     the ten-character team id of the certificate
#   NOTARY_KEY_FILE   the path of the AuthKey_<id>.p8 file
#   NOTARY_KEY_ID     the key id
#   NOTARY_ISSUER_ID  the issuer id of the keys page
#
# With no APPLE_TEAM_ID, the script signs ad hoc and does not notarize. The
# .dmg is then build/zslice-<version>-macos-universal-unsigned.dmg, and
# Gatekeeper blocks it on other Macs. With the variables, it is
# build/zslice-<version>-macos-universal.dmg.
#
# The version is the tag with no v (0.6.0-beta). The bundle gets the
# numbers only (0.6.0), because CFBundleShortVersionString has three
# integers.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${1:?usage: release.sh <version> <build-number>}"
BUILD="${2:?usage: release.sh <version> <build-number>}"
NUMBERS="${VERSION%%-*}"

DERIVED="$PWD/build/release"
APP="$DERIVED/Build/Products/Release/zslice.app"
if [ -n "${APPLE_TEAM_ID:-}" ]; then
    : "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
    DMG="$PWD/build/zslice-$VERSION-macos-universal.dmg"
    SIGN=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application"
          "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
else
    echo "release.sh: no APPLE_TEAM_ID: the app is signed ad hoc and not notarized" >&2
    DMG="$PWD/build/zslice-$VERSION-macos-universal-unsigned.dmg"
    SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
NOTARY=(--key "${NOTARY_KEY_FILE:-}" --key-id "${NOTARY_KEY_ID:-}" --issuer "${NOTARY_ISSUER_ID:-}")

# Submits one file, waits for the result, and stops with the log of Apple
# when the status is not Accepted. The exit code of notarytool does not
# give the status, so the script reads it from the JSON.
notarize() {
    local out id status
    out=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json)
    id=$(echo "$out" | plutil -extract id raw -o - -)
    status=$(echo "$out" | plutil -extract status raw -o - -)
    echo "notary: $(basename "$1") $status ($id)"
    if [ "$status" != "Accepted" ]; then
        xcrun notarytool log "$id" "${NOTARY[@]}" >&2
        return 1
    fi
}

# Info.plist has fixed version strings. The script sets them for the build,
# and puts the file back at the end.
plist_copy=$(mktemp)
cp Info.plist "$plist_copy"
trap 'cp "$plist_copy" Info.plist; rm -f "$plist_copy"' EXIT
plutil -replace CFBundleShortVersionString -string "$NUMBERS" Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Info.plist

echo "==> xcodebuild Release ($VERSION, build $BUILD)"
xcodebuild -project ZSlice.xcodeproj -scheme ZSlice -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    ENABLE_HARDENED_RUNTIME=YES "${SIGN[@]}" build

codesign --verify --strict --deep "$APP"
archs=$(lipo -archs "$APP/Contents/MacOS/zslice")
echo "architectures: $archs"
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "release.sh: not universal" >&2; exit 1 ;; esac

if [ -n "${APPLE_TEAM_ID:-}" ]; then
    echo "==> notarize the app"
    ZIP="$DERIVED/zslice.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"
fi

# The app next to a link to /Applications, on a compressed read-only image.
echo "==> make the dmg"
STAGE="$DERIVED/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/zslice.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil sometimes cannot detach its temporary image on a busy machine.
for attempt in 1 2 3; do
    if hdiutil create -volname "zslice" -srcfolder "$STAGE" -format UDZO -ov "$DMG"; then
        break
    fi
    [ "$attempt" = 3 ] && exit 1
    sleep 5
done

# The dmg has its own signature and ticket, so Gatekeeper accepts the
# download, and the app in it opens with no network.
if [ -n "${APPLE_TEAM_ID:-}" ]; then
    codesign --sign "Developer ID Application" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type execute -v "$APP"
fi
echo "==> $DMG"
