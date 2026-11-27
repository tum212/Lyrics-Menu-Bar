#!/bin/bash
# ============================================================
# build_dmg.sh - Build LyricsMenuBar and package into a
#                polished DMG with background art + Gatekeeper bypass
#
# Usage:
#   bash build_dmg.sh          → builds both Standard (14.2+) and Lite (13.0+)
#   bash build_dmg.sh sonoma   → builds Standard (14.2+) only
#   bash build_dmg.sh lite     → builds Lite (13.0+) only
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_TARGET="${1:-all}"

# ---- helper: build one DMG ----
build_dmg() {
    local LABEL="$1"          # e.g. "Sonoma" or "Lite"
    local MIN_OS="$2"         # e.g. "14.2" or "13.0"
    local APP_TITLE="$3"      # e.g. "Lyrics Menu Bar" or "Lyrics Menu Bar Lite"
    local PLIST_SRC="$4"      # e.g. "Sources/LyricsMenuBar/Info.plist" or "Sources/LyricsMenuBar/Info-Lite.plist"
    local DMG_NAME="$5"       # e.g. "LyricsMenuBar-1.3.1.dmg" or "LyricsMenuBar-Lite-1.3.1.dmg"
    local VOLUME_NAME="$6"    # e.g. "Lyrics Menu Bar" or "Lyrics Menu Bar Lite"
    local DMG_STAGING="$SCRIPT_DIR/.dmg_staging_${LABEL}"

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Building ${APP_TITLE} for macOS ${LABEL} (${MIN_OS}+)  ║"
    echo "╚══════════════════════════════════════════════════════╝"

    # ----- 1. BUILD -------------------------------------------------------
    cd "$SCRIPT_DIR"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        swift build -c release --arch arm64 --arch x86_64 \
        2>&1 | grep -v "^warning:" || true

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

    # Background + volume icon
    if [ -f "$SCRIPT_DIR/dmg_background.png" ]; then
        mkdir -p "$DMG_STAGING/.background"
        cp "$SCRIPT_DIR/dmg_background.png" "$DMG_STAGING/.background/background.png"
    fi
    if [ -f "$SCRIPT_DIR/icon.icns" ]; then
        cp "$SCRIPT_DIR/icon.icns" "$DMG_STAGING/.VolumeIcon.icns"
    fi

    # OS label file (visible in DMG so user knows which version)
    echo "For macOS ${MIN_OS}+ (${LABEL})" > "$DMG_STAGING/macOS_${LABEL}_${MIN_OS}+.txt"

    # ----- 5. WRITABLE DMG -----------------------------------------------
    local TEMP_DMG="$SCRIPT_DIR/.temp_rw_${LABEL}.dmg"
    rm -f "$TEMP_DMG" "$SCRIPT_DIR/$DMG_NAME"

    # Force-eject any previously mounted volume first
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

    local MOUNT_POINT
    MOUNT_POINT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | \
                  grep "/Volumes/" | sed -E 's/.*(\/Volumes\/.*)/\1/')
    echo "   Mounted at: $MOUNT_POINT"
    sleep 2

    # Set Finder layout via AppleScript
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

    local SIZE
    SIZE=$(du -sh "$SCRIPT_DIR/$DMG_NAME" | cut -f1)
    echo ""
    echo "✅ ${DMG_NAME} (${SIZE}) → $SCRIPT_DIR/"
}

# ---- dispatch ----
case "$BUILD_TARGET" in
    sonoma|mac|14)
        build_dmg "Sonoma" "14.2" "Lyrics Menu Bar" "Sources/LyricsMenuBar/Info.plist" "LyricsMenuBar-1.3.1.dmg" "Lyrics Menu Bar"
        ;;
    lite|ventura|13)
        build_dmg "Lite" "13.0" "Lyrics Menu Bar Lite" "Sources/LyricsMenuBar/Info-Lite.plist" "LyricsMenuBar-Lite-1.3.1.dmg" "Lyrics Menu Bar Lite"
        ;;
    all|*)
        build_dmg "Sonoma" "14.2" "Lyrics Menu Bar" "Sources/LyricsMenuBar/Info.plist" "LyricsMenuBar-1.3.1.dmg" "Lyrics Menu Bar"
        build_dmg "Lite" "13.0" "Lyrics Menu Bar Lite" "Sources/LyricsMenuBar/Info-Lite.plist" "LyricsMenuBar-Lite-1.3.1.dmg" "Lyrics Menu Bar Lite"
        ;;
esac

echo ""
echo "======================================="
echo "DMG files ready to distribute:"
ls -lh "$SCRIPT_DIR"/*.dmg 2>/dev/null | awk '{print "   "$NF, "("$5")"}'
echo ""
echo "Gatekeeper tips for recipients:"
echo "   - Right-click app -> Open (bypass once)"
echo "   - Or: xattr -cr '/Applications/Lyrics Menu Bar.app'"
echo "======================================="
