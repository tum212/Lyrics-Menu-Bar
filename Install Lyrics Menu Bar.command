#!/bin/bash
# ============================================================
#  Install Lyrics Menu Bar — Post-install Gatekeeper bypass
#  This script runs from the DMG to install and fix permissions
# ============================================================

APP_SOURCE="$(dirname "$0")/Lyrics Menu Bar.app"
APP_DEST="/Applications/Lyrics Menu Bar.app"

echo ""
echo "🎵 Installing Lyrics Menu Bar..."
echo ""

# Remove any old version
if [ -d "$APP_DEST" ]; then
  echo "   Removing old version..."
  rm -rf "$APP_DEST"
fi

# Copy to Applications
echo "   Copying to Applications..."
cp -R "$APP_SOURCE" "$APP_DEST"

# Strip quarantine (fixes "damaged or can't be opened" on Apple Silicon)
echo "   Removing quarantine flags..."
xattr -cr "$APP_DEST"

# Re-sign with ad-hoc identity (required after quarantine strip)
echo "   Applying ad-hoc signature..."
codesign --force --deep --sign - --entitlements "$(dirname "$0")/LyricsMenuBar.entitlements" "$APP_DEST" 2>/dev/null

# Remove from Gatekeeper assessment (requires admin)
echo "   Bypassing Gatekeeper (requires admin password)..."
sudo spctl --add "$APP_DEST" 2>/dev/null || true

echo ""
echo "✅ Installation complete!"
echo "   Lyrics Menu Bar is now in your Applications folder."
echo ""
echo "   Launch it from Applications or Spotlight (⌘Space → Lyrics Menu Bar)"
echo ""

# Open the app
open "$APP_DEST"
