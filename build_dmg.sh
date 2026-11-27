#!/bin/bash
# ============================================================
# build_dmg.sh - Build Lyrics Menu Bar (Universal macOS 13.0+)
#                and package into a polished DMG
#
# Usage:
#   bash build_dmg.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_TITLE="Lyrics Menu Bar"
PLIST_SRC="Sources/LyricsMenuBar/Info.plist"
DMG_NAME="LyricsMenuBar-2.0.0.dmg"
VOLUME_NAME="Lyrics Menu Bar"
MIN_OS="13.0"
DMG_STAGING="$SCRIPT_DIR/.dmg_staging_Universal"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Building ${APP_TITLE} v2.0.0 Rust+AppKit (macOS ${MIN_OS}+) ║"
echo "╚═══════════════════════════════════════════════════════════╝"

# ----- 0. BUILD RUST CORE ENGINE (arm64 + x86_64 -> universal) -------
echo "=== Building Rust Core Engine (lyrics-core) ==="
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MIN_OS}"
cd "$SCRIPT_DIR"

cargo build --release --manifest-path rust/lyrics-core/Cargo.toml --target aarch64-apple-darwin
cargo build --release --manifest-path rust/lyrics-core/Cargo.toml --target x86_64-apple-darwin

mkdir -p "$SCRIPT_DIR/rust/target/universal"
lipo -create \
    "$SCRIPT_DIR/rust/lyrics-core/target/aarch64-apple-darwin/release/liblyrics_core.a" \
    "$SCRIPT_DIR/rust/lyrics-core/target/x86_64-apple-darwin/release/liblyrics_core.a" \
    -output "$SCRIPT_DIR/rust/target/universal/liblyrics_core.a"
echo "   Rust universal staticlib complete ✓"

# ----- 1. BUILD -------------------------------------------------------
cd "$SCRIPT_DIR"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release --arch arm64 --arch x86_64

BINARY_PATH=""
if [ -f "$SCRIPT_DIR/.build/apple/Products/Release/LyricsMenuBar" ]; then
    BINARY_PATH="$SCRIPT_DIR/.build/apple/Products/Release/LyricsMenuBar"
elif [ -f "$SCRIPT_DIR/.build/release/LyricsMenuBar" ]; then
    BINARY_PATH="$SCRIPT_DIR/.build/release/LyricsMenuBar"
fi

if [ -z "$BINARY_PATH" ]; then
    echo "❌ Binary not found!"
    exit 1
fi

echo "   Build complete ✓"

# ----- 2. ASSEMBLE APP BUNDLE -----------------------------------------
echo "=== Packaging ${APP_TITLE}.app ==="
mkdir -p "$SCRIPT_DIR/${APP_TITLE}.app/Contents/MacOS"
mkdir -p "$SCRIPT_DIR/${APP_TITLE}.app/Contents/Resources"
cp "$BINARY_PATH" "$SCRIPT_DIR/${APP_TITLE}.app/Contents/MacOS/LyricsMenuBar"
cp icon.icns "$SCRIPT_DIR/${APP_TITLE}.app/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$PLIST_SRC" "$SCRIPT_DIR/${APP_TITLE}.app/Contents/Info.plist"

# ----- 3. CODE SIGNING ------------------------------------------------
echo "=== Signing app bundle ==="
codesign --force --deep --sign - --entitlements "$SCRIPT_DIR/LyricsMenuBar.entitlements" "$SCRIPT_DIR/${APP_TITLE}.app" 2>/dev/null || true
echo "   Signing complete ✓"

# ----- 4. CREATE STAGING DIRECTORY -----------------------------------------------
echo "=== Creating DMG staging area ==="
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$SCRIPT_DIR/${APP_TITLE}.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

if [ -f "$SCRIPT_DIR/dmg_background.png" ]; then
    mkdir -p "$DMG_STAGING/.background"
    cp "$SCRIPT_DIR/dmg_background.png" "$DMG_STAGING/.background/background.png"
fi
if [ -f "$SCRIPT_DIR/icon.icns" ]; then
    cp "$SCRIPT_DIR/icon.icns" "$DMG_STAGING/.VolumeIcon.icns"
fi

echo "Universal App (Apple Silicon + Intel) for macOS ${MIN_OS}+" > "$DMG_STAGING/macOS_${MIN_OS}+_Universal.txt"

# ----- 5. WRITABLE DMG -----------------------------------------------
TEMP_DMG="$SCRIPT_DIR/.temp_rw_Universal.dmg"
rm -f "$TEMP_DMG" "$SCRIPT_DIR/$DMG_NAME"

for vol in "/Volumes/${VOLUME_NAME}" "/Volumes/${VOLUME_NAME} "* /Volumes/Spoticat /Volumes/Spoticat\ *; do
    if [ -d "$vol" ]; then
        echo "   Ejecting stale mount: $vol"
        hdiutil detach "$vol" -force 2>/dev/null || diskutil eject "$vol" 2>/dev/null || true
        sleep 1
    fi
done

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW \
    "$TEMP_DMG"

MOUNT_POINT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | \
              grep "/Volumes/" | sed -E 's/.*(\/Volumes\/.*)/\1/')
echo "   Mounted at: $MOUNT_POINT"
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 500}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_TITLE}.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

echo "   Layout applied ✓"
sync
sleep 1
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || diskutil eject "$MOUNT_POINT" 2>/dev/null || true

# ----- 6. COMPRESS -----------------------------------------------
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$SCRIPT_DIR/$DMG_NAME"

xattr -cr "$SCRIPT_DIR/$DMG_NAME" 2>/dev/null || true

# ----- 7. CLEANUP -----------------------------------------------
rm -rf "$DMG_STAGING" "$TEMP_DMG"

SIZE=$(du -sh "$SCRIPT_DIR/$DMG_NAME" | cut -f1)
echo ""
echo "✅ ${DMG_NAME} (${SIZE}) → $SCRIPT_DIR/"
echo ""
echo "======================================="
echo "DMG ready to distribute: $SCRIPT_DIR/$DMG_NAME"
echo ""
echo "Gatekeeper tips for recipients:"
echo "   - Right-click app -> Open (bypass once)"
echo "   - Or: xattr -cr '/Applications/Lyrics Menu Bar.app'"
echo "======================================="
