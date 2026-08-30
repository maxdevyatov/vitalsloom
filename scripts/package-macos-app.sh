#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/dist"
OUTPUT_APP="$OUTPUT_DIRECTORY/VitalsLoom.app"
TEMP_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/vitalsloom-package.XXXXXX")
TEMP_APP="$TEMP_DIRECTORY/VitalsLoom.app"
ICONSET_DIRECTORY="$TEMP_DIRECTORY/AppIcon.iconset"

cleanup() {
    rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

cd "$PROJECT_DIRECTORY"
swift build -c release
BIN_DIRECTORY=$(swift build -c release --show-bin-path)

mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources" "$OUTPUT_DIRECTORY"
install -m 755 "$BIN_DIRECTORY/VitalsLoom" "$TEMP_APP/Contents/MacOS/VitalsLoom"
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
codesign --force --sign - --timestamp=none --identifier com.mdevyatov.vitalsloom "$TEMP_APP"
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"

if [[ -e "$OUTPUT_APP" ]]; then
    rm -rf "$OUTPUT_APP"
fi
ditto "$TEMP_APP" "$OUTPUT_APP"

echo "$OUTPUT_APP"
