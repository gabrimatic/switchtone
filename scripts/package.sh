#!/bin/zsh
# Builds Switchtone from a clean tree and writes the release files into ./dist:
#   Switchtone-<version>.zip   the app, for install.sh and direct download
#   Switchtone-<version>.dmg   the app next to an Applications shortcut
#   SHA256SUMS.txt        checksums of both
# Then it checks what it wrote. The version comes from Resources/Info.plist. A release is always signed
# ad hoc, so it never carries a certificate that exists only on the Mac that built it.
set -euo pipefail
cd "${0:A:h}/.."

EXTENSIONS=(SwitchtoneControls)
EXTENSION_PLISTS=(Extensions/SwitchtoneControls/Info.plist)

fail() { echo "error: $1" >&2; exit 1; }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1"; }

[[ "$(uname -m)" == "arm64" ]] || fail "Switchtone builds on Apple silicon only."
VERSION=$(version_of Resources/Info.plist)
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "version \"$VERSION\" in Resources/Info.plist is not x.y.z."
for plist in $EXTENSION_PLISTS; do
  [[ "$(version_of $plist)" == "$VERSION" ]] || fail "$plist is at $(version_of $plist), the app at $VERSION."
done

ZIP="Switchtone-$VERSION.zip"
DMG="Switchtone-$VERSION.dmg"
APP=build/Switchtone.app
WORK=$(mktemp -d)
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

SWITCHTONE_SIGN_IDENTITY=- ./build.sh
[[ -d "$APP" ]] || fail "$APP was not built."

rm -rf dist
mkdir dist

# The zip: ditto keeps the bundle's signature, symlinks and extended attributes intact.
ditto -c -k --keepParent "$APP" "dist/$ZIP"

# The disk image: the app and an Applications shortcut to drag it onto.
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Switchtone.app"
ln -s /Applications "$WORK/dmg/Applications"
for attempt in 1 2 3; do
  hdiutil create -quiet -volname "Switchtone $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "dist/$DMG" && break
  [[ $attempt -lt 3 ]] || fail "hdiutil could not create the disk image."
  sleep 3
done

(cd dist && shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS.txt)

# Verify what was written, not what was meant to be written.
verify_app() { # <app> <label>
  local app=$1 label=$2
  codesign --verify --strict --deep "$app" || fail "$label: the signature does not verify."
  [[ "$(lipo -archs "$app/Contents/MacOS/Switchtone")" == "arm64" ]] || fail "$label: Switchtone is not arm64 only."
  [[ "$(version_of "$app/Contents/Info.plist")" == "$VERSION" ]] || fail "$label: wrong version."
  [[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "$label: the icon is missing."
  [[ -d "$app/Contents/Resources/Metadata.appintents" ]] || fail "$label: the App Intents metadata is missing."
  for extension in $EXTENSIONS; do
    local bundle="$app/Contents/PlugIns/$extension.appex"
    [[ -d "$bundle" ]] || fail "$label: $extension.appex is missing."
    codesign -d --entitlements - "$bundle" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' \
      || fail "$label: $extension.appex has no sandbox entitlement."
    [[ "$(version_of "$bundle/Contents/Info.plist")" == "$VERSION" ]] || fail "$label: $extension.appex has the wrong version."
  done
  echo "  ok: $label"
}

echo "Verifying:"
mkdir "$WORK/unzip"
ditto -x -k "dist/$ZIP" "$WORK/unzip"
verify_app "$WORK/unzip/Switchtone.app" "zip"

hdiutil verify -quiet "dist/$DMG" || fail "the disk image does not verify."
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach "dist/$DMG" -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT"
[[ -L "$MOUNT/Applications" ]] || fail "the disk image has no Applications shortcut."
verify_app "$MOUNT/Switchtone.app" "dmg"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

(cd dist && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || fail "the checksums do not match."
echo "  ok: checksums"

rm -rf build
echo
echo "Packaged Switchtone $VERSION in dist/:"
ls -lh dist | tail -n +2
