#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ARCH="${ARCH:-$(uname -m)}"
WITH_TOOLS=0
MAKE_DMG=0
WITH_ROOT_TOOLS=0
WITH_EDL_TOOLS=0
for option in "$@"; do
    case "$option" in
        --with-platform-tools) WITH_TOOLS=1 ;;
        --dmg) MAKE_DMG=1 ;;
        --with-root-tools) WITH_ROOT_TOOLS=1 ;;
        --with-edl-tools) WITH_EDL_TOOLS=1 ;;
        *) echo "Usage: $0 [--with-platform-tools] [--with-root-tools] [--with-edl-tools] [--dmg] (ARCH=arm64 or x86_64)" >&2; exit 2 ;;
    esac
done
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
ROOT_TOOLS="$PROJECT_DIR/.cache/packaged-tools/$ARCH"
EDL_TOOLS="$PROJECT_DIR/.cache/packaged-edl/$ARCH"
if [ "$WITH_EDL_TOOLS" = 1 ] && [ ! -f "$EDL_TOOLS/EDL_NATIVE_TOOLS.json" ]; then
    echo "Build EDL tools first: python3 macOS/scripts/build-edl-tools.py --arch $ARCH" >&2
    exit 2
fi
if [ "$WITH_ROOT_TOOLS" = 1 ] && [ ! -f "$ROOT_TOOLS/NATIVE_TOOLS.json" ]; then
    echo "Build native tools first: python3 macOS/scripts/build-native-tools.py --arch $ARCH" >&2
    exit 2
fi

OUTPUT_DIR="${VIOLET_DIST_DIR:-$PROJECT_DIR/dist/$ARCH}"
APP="$OUTPUT_DIR/VioletToolBox.app"
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/.cache"
xcrun swift build --package-path "$PROJECT_DIR" -c release --arch "$ARCH"
BINARY_DIR="$(xcrun swift build --package-path "$PROJECT_DIR" -c release --arch "$ARCH" --show-bin-path)"
# Only replace the generated app in this script's dedicated output directory.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/VioletToolBox" "$APP/Contents/MacOS/VioletToolBox"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$PROJECT_DIR/README.md" "$APP/Contents/Resources/README.md"
cp "$PROJECT_DIR/TESTING.md" "$APP/Contents/Resources/TESTING.md"
cp "$PROJECT_DIR/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"
cp "$PROJECT_DIR/PORTING_STATUS.md" "$APP/Contents/Resources/PORTING_STATUS.md"
cp "$PROJECT_DIR/NATIVE_TOOLS.md" "$APP/Contents/Resources/NATIVE_TOOLS.md"
cp "$PROJECT_DIR/EDL_NATIVE.md" "$APP/Contents/Resources/EDL_NATIVE.md"
cp "$PROJECT_DIR/REMOTE_FIRMWARE.md" "$APP/Contents/Resources/REMOTE_FIRMWARE.md"
cp "$PROJECT_DIR/DOWNGRADE_PORT.md" "$APP/Contents/Resources/DOWNGRADE_PORT.md"
mkdir -p "$APP/Contents/Resources/ZstdLicense"
cp "$PROJECT_DIR/Sources/CZstdDecoder/vendor/LICENSE" "$APP/Contents/Resources/ZstdLicense/LICENSE"
cp "$PROJECT_DIR/Sources/CZstdDecoder/UPSTREAM.json" "$APP/Contents/Resources/ZstdLicense/UPSTREAM.json"
if [ "$WITH_EDL_TOOLS" = 1 ]; then
    cp -R "$EDL_TOOLS/edl-tools" "$APP/Contents/Resources/edl-tools"
    cp -R "$EDL_TOOLS/EDLLicenses" "$APP/Contents/Resources/EDLLicenses"
    cp -R "$EDL_TOOLS/EDLSources" "$APP/Contents/Resources/EDLSources"
    cp "$EDL_TOOLS/EDL_NATIVE_TOOLS.json" "$APP/Contents/Resources/EDL_NATIVE_TOOLS.json"
fi
git -C "$REPO_DIR" rev-parse HEAD > "$APP/Contents/Resources/UPSTREAM_COMMIT.txt"

# Preserve the upstream icon, converting its highest-resolution representation.
ICONSET="$PROJECT_DIR/.cache/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -s format png "$REPO_DIR/VioletToolBox/logo2.ico" --out "$PROJECT_DIR/.cache/logo.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/.cache/logo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PROJECT_DIR/.cache/logo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [ "$WITH_TOOLS" = 1 ]; then
    ARCHIVE="$PROJECT_DIR/.cache/platform-tools-darwin.zip"
    if [ ! -f "$ARCHIVE" ]; then
        curl -fL --retry 2 --connect-timeout 20 --max-time 300 \
            https://dl.google.com/android/repository/platform-tools-latest-darwin.zip -o "$ARCHIVE.part"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    unzip -q "$ARCHIVE" -d "$APP/Contents/Resources"
    shasum -a 256 "$ARCHIVE" > "$APP/Contents/Resources/PLATFORM_TOOLS_SHA256.txt"
fi

if [ "$WITH_ROOT_TOOLS" = 1 ]; then
    ditto "$ROOT_TOOLS/native-tools" "$APP/Contents/Resources/native-tools"
    ditto "$ROOT_TOOLS/RootPayloads" "$APP/Contents/Resources/RootPayloads"
    ditto "$ROOT_TOOLS/NativeToolLicenses" "$APP/Contents/Resources/NativeToolLicenses"
    cp "$ROOT_TOOLS/NATIVE_TOOLS.json" "$APP/Contents/Resources/NATIVE_TOOLS.json"
fi

# Ad-hoc signing supports local execution. Public distribution requires a Developer ID.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/VioletToolBox-macOS-$ARCH.zip"
if [ "$MAKE_DMG" = 1 ]; then
    STAGE="$(mktemp -d "$PROJECT_DIR/.cache/dmg.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    ditto "$APP" "$STAGE/VioletToolBox.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "VioletToolBox" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT_DIR/VioletToolBox-macOS-$ARCH.dmg"
fi
echo "Built: $APP"
