#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/dist"
OUTPUT_APP="$OUTPUT_DIRECTORY/VitalsLoom.app"
TEMP_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/vitalsloom-package.XXXXXX")
TEMP_APP="$TEMP_DIRECTORY/VitalsLoom.app"
ICONSET_DIRECTORY="$TEMP_DIRECTORY/AppIcon.iconset"
DMG_STAGING_DIRECTORY="$TEMP_DIRECTORY/dmg"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_DIRECTORY/Packaging/Info.plist")
OUTPUT_DMG="$OUTPUT_DIRECTORY/VitalsLoom-$VERSION-macOS-universal-unsigned.dmg"
OUTPUT_CHECKSUM="$OUTPUT_DMG.sha256"
ARM_TRIPLE="arm64-apple-macosx14.0"
INTEL_TRIPLE="x86_64-apple-macosx14.0"

cleanup() {
    rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

cd "$PROJECT_DIRECTORY"
swift build -c release --triple "$ARM_TRIPLE"
swift build -c release --triple "$INTEL_TRIPLE"
ARM_BIN_DIRECTORY=$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)
INTEL_BIN_DIRECTORY=$(swift build -c release --triple "$INTEL_TRIPLE" --show-bin-path)

mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources" "$OUTPUT_DIRECTORY"
lipo -create \
    "$ARM_BIN_DIRECTORY/VitalsLoom" \
    "$INTEL_BIN_DIRECTORY/VitalsLoom" \
    -output "$TEMP_APP/Contents/MacOS/VitalsLoom"
chmod 755 "$TEMP_APP/Contents/MacOS/VitalsLoom"
install -m 644 "$PROJECT_DIRECTORY/Packaging/Info.plist" "$TEMP_APP/Contents/Info.plist"
mkdir -p "$TEMP_APP/Contents/Resources/Licenses"
install -m 644 "$PROJECT_DIRECTORY/LICENSE" "$TEMP_APP/Contents/Resources/Licenses/VitalsLoom-LICENSE.txt"
install -m 644 "$PROJECT_DIRECTORY/THIRD_PARTY_NOTICES.md" "$TEMP_APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
printf 'APPL????' > "$TEMP_APP/Contents/PkgInfo"

mkdir -p "$ICONSET_DIRECTORY"
sips -z 16 16 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_16x16.png" >/dev/null
sips -z 32 32 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_32x32.png" >/dev/null
sips -z 64 64 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_128x128.png" >/dev/null
sips -z 256 256 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_256x256.png" >/dev/null
sips -z 512 512 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$PROJECT_DIRECTORY/Packaging/AppIcon.png" --out "$ICONSET_DIRECTORY/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIRECTORY" -o "$TEMP_APP/Contents/Resources/AppIcon.icns"

plutil -lint "$TEMP_APP/Contents/Info.plist"
codesign --force --sign - --options runtime --timestamp=none --identifier com.mdevyatov.vitalsloom "$TEMP_APP"
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"
lipo -archs "$TEMP_APP/Contents/MacOS/VitalsLoom"

if [[ -e "$OUTPUT_APP" ]]; then
    rm -rf "$OUTPUT_APP"
fi
ditto "$TEMP_APP" "$OUTPUT_APP"

mkdir -p "$DMG_STAGING_DIRECTORY"
ditto "$TEMP_APP" "$DMG_STAGING_DIRECTORY/VitalsLoom.app"
ln -s /Applications "$DMG_STAGING_DIRECTORY/Applications"
install -m 644 "$PROJECT_DIRECTORY/Packaging/INSTALL.txt" "$DMG_STAGING_DIRECTORY/INSTALL.txt"

rm -f "$OUTPUT_DMG" "$OUTPUT_CHECKSUM"
hdiutil create \
    -volname "VitalsLoom $VERSION" \
    -srcfolder "$DMG_STAGING_DIRECTORY" \
    -format UDZO \
    -ov \
    "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"

cd "$OUTPUT_DIRECTORY"
shasum -a 256 "${OUTPUT_DMG:t}" > "${OUTPUT_CHECKSUM:t}"

echo "$OUTPUT_APP"
echo "$OUTPUT_DMG"
echo "$OUTPUT_CHECKSUM"
