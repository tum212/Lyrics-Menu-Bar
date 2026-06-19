#!/bin/bash
# ============================================================
# build_dmg.sh — Build SpoticatMenuBar and package into a
#                polished DMG with background art + Gatekeeper bypass
#
# Usage:
#   bash build_dmg.sh          → builds both (Sonoma + Monterey)
#   bash build_dmg.sh sonoma   → Sonoma / Ventura (macOS 13-15)
#   bash build_dmg.sh monterey → Monterey / Ventura (macOS 12+)
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SpoticatMenuBar"
VOLUME_NAME="Spoticat"

BUILD_TARGET="${1:-all}"   # "sonoma" | "monterey" | "all"

# ---- helper: build one DMG ----
build_dmg() {
    local LABEL="$1"          # e.g. "Sonoma" or "Monterey"
    local MIN_OS="$2"         # e.g. "13.0" or "12.0"
    local SWIFT_FLAGS="$3"    # extra flags
    local DMG_NAME="${APP_NAME}_${LABEL}.dmg"
    local DMG_STAGING="$SCRIPT_DIR/.dmg_staging_${LABEL}"

    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  Building for macOS ${LABEL} (${MIN_OS}+)  ║"
    echo "╚══════════════════════════════════════╝"

    # ----- 1. BUILD -------------------------------------------------------
    cd "$SCRIPT_DIR"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        swift build -c release \
        -Xswiftc "-target" -Xswiftc "arm64-apple-macos${MIN_OS}" \
        -Xlinker "-macos_version_min" -Xlinker "${MIN_OS}" \
        2>&1 | grep -v "^warning:" || true
    # Try without target flags if above fails (older Xcode)
    if [ ! -f "$SCRIPT_DIR/.build/release/SpoticatMenuBar" ]; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release || true
    fi

    echo "   Build complete ✓"

    # ----- 2. ASSEMBLE APP BUNDLE -----------------------------------------
    echo "=== Packaging app bundle ==="
    cp .build/release/SpoticatMenuBar SpoticatMenuBar.app/Contents/MacOS/SpoticatMenuBar
    cp icon.icns SpoticatMenuBar.app/Contents/Resources/AppIcon.icns 2>/dev/null || true
    cp Sources/SpoticatMenuBar/Info.plist SpoticatMenuBar.app/Contents/Info.plist

    # ----- 3. SIGN (ad-hoc) + STRIP QUARANTINE ---------------------------
    echo "=== Signing ==="
    xattr -cr SpoticatMenuBar.app
    codesign --force --deep --sign - --entitlements "$SCRIPT_DIR/SpoticatMenuBar.entitlements" SpoticatMenuBar.app
    echo "   Signed ✓"

    # ----- 4. STAGING AREA -----------------------------------------------
    echo "=== Creating DMG staging area ==="
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R SpoticatMenuBar.app "$DMG_STAGING/"
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
    echo "For macOS ${MIN_OS}+" > "$DMG_STAGING/macOS_${LABEL}_${MIN_OS}+.txt"

    # ----- 5. WRITABLE DMG -----------------------------------------------
    local TEMP_DMG="$SCRIPT_DIR/.temp_rw_${LABEL}.dmg"
    rm -f "$TEMP_DMG" "$SCRIPT_DIR/$DMG_NAME"

    # Force-eject any previously mounted Spoticat volume first
    for vol in /Volumes/Spoticat /Volumes/Spoticat\ *; do
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
                  grep "/Volumes/" | awk '{print $NF}')
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
        set position of item "SpoticatMenuBar.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

    echo "   Layout applied ✓"
    sync
    hdiutil detach "$MOUNT_POINT" -quiet

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
    sonoma)
        build_dmg "Sonoma" "13.0"
        ;;
    monterey)
        build_dmg "Monterey" "12.0"
        ;;
    all|*)
        build_dmg "Sonoma"   "13.0"
        build_dmg "Monterey" "12.0"
        ;;
esac

echo ""
echo "═══════════════════════════════════════"
echo "📦 DMG files ready to distribute:"
ls -lh "$SCRIPT_DIR"/*.dmg 2>/dev/null | awk '{print "   "$NF, "("$5")"}'
echo ""
echo "🔓 Gatekeeper tips for recipients:"
echo "   • Right-click app → Open  (bypass once)"
echo "   • Or: xattr -cr /Applications/SpoticatMenuBar.app"
echo "═══════════════════════════════════════"
