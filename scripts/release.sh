#!/usr/bin/env bash
# Builds, signs (Developer ID, cloud signing), notarizes and packages PRTray.dmg.
#
# Needs an App Store Connect API key (Admin role for cloud signing) and these
# variables, either exported or in scripts/release.env (gitignored):
#   TEAM_ID        Apple Developer team ID
#   ASC_ISSUER_ID  App Store Connect API issuer ID
#   ASC_KEY_ID     App Store Connect API key ID
#   ASC_KEY_PATH   path to AuthKey_<id>.p8 (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# shellcheck disable=SC1091
[ -f scripts/release.env ] && source scripts/release.env
: "${TEAM_ID:?set TEAM_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

OUT="$ROOT/build/release"
ARCHIVE="$OUT/PRTray.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/PRTray.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> xcodegen"
xcodegen generate

echo "==> archive"
xcodebuild archive \
  -project PRTray.xcodeproj -scheme PRTray -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  "${AUTH[@]}" | tail -5

echo "==> export (developer-id)"
sed "s/__TEAM_ID__/$TEAM_ID/" scripts/ExportOptions.plist > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  "${AUTH[@]}" | tail -5

APP="$EXPORT/PRTray.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Volume icon: the app icon, shown on the mounted disk and the .dmg file.
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  cp "PRTray/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@1x.png" "$ICONSET/icon_${s}x${s}.png"
  cp "PRTray/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@2x.png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns"
SetFile -c icnC "$STAGE/.VolumeIcon.icns" 2>/dev/null || true
hdiutil create -volname "PRTray" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
# Attach the icon to the .dmg file itself
if command -v fileicon >/dev/null; then fileicon set "$DMG" docs/icon-1024.png >/dev/null || true; fi
DEVID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [ -n "$DEVID" ]; then codesign --force --sign "$DEVID" --timestamp "$DMG"; fi

echo "==> notarize"
xcrun notarytool submit "$DMG" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "==> staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> gatekeeper"
spctl -a -vv -t install "$DMG"
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet
spctl -a -vv "$MNT/PRTray.app"
hdiutil detach "$MNT" -quiet

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed "s/sha256 \".*\"/sha256 \"$SHA\"/" packaging/prtray.rb > "$OUT/prtray.rb"
cp "$OUT/prtray.rb" packaging/prtray.rb

echo
echo "DMG:    $DMG"
echo "sha256: $SHA"
echo "cask:   packaging/prtray.rb"
