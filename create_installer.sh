#!/bin/bash
set -e

ICON_SRC="/Users/engineer/.gemini/antigravity/brain/5ad97905-f7f0-4f19-9fee-7de735399e54/spoticat_icon_1781870092072.png"
APP_NAME="Lyrics Menu Bar.app"
DMG_NAME="LyricsMenuBar-Universal.dmg"
VOL_NAME="LyricsMenuBar"

echo "Generating ICNS..."
rm -rf MyIcon.iconset
mkdir MyIcon.iconset
sips -z 16 16     "$ICON_SRC" --out MyIcon.iconset/icon_16x16.png > /dev/null
sips -z 32 32     "$ICON_SRC" --out MyIcon.iconset/icon_16x16@2x.png > /dev/null
sips -z 32 32     "$ICON_SRC" --out MyIcon.iconset/icon_32x32.png > /dev/null
sips -z 64 64     "$ICON_SRC" --out MyIcon.iconset/icon_32x32@2x.png > /dev/null
sips -z 128 128   "$ICON_SRC" --out MyIcon.iconset/icon_128x128.png > /dev/null
sips -z 256 256   "$ICON_SRC" --out MyIcon.iconset/icon_128x128@2x.png > /dev/null
sips -z 256 256   "$ICON_SRC" --out MyIcon.iconset/icon_256x256.png > /dev/null
sips -z 512 512   "$ICON_SRC" --out MyIcon.iconset/icon_256x256@2x.png > /dev/null
sips -z 512 512   "$ICON_SRC" --out MyIcon.iconset/icon_512x512.png > /dev/null
sips -z 1024 1024 "$ICON_SRC" --out MyIcon.iconset/icon_512x512@2x.png > /dev/null
iconutil -c icns MyIcon.iconset
mv MyIcon.icns AppIcon.icns
rm -rf MyIcon.iconset

echo "Preparing App..."
rm -rf dmg_stage
mkdir dmg_stage
cp -R $APP_NAME dmg_stage/
ln -s /Applications dmg_stage/Applications

echo "Adding App Icon..."
mkdir -p dmg_stage/$APP_NAME/Contents/Resources
cp AppIcon.icns dmg_stage/$APP_NAME/Contents/Resources/AppIcon.icns
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" dmg_stage/$APP_NAME/Contents/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon.icns" dmg_stage/$APP_NAME/Contents/Info.plist

echo "Removing quarantine and codesigning..."
xattr -cr dmg_stage/$APP_NAME
codesign --force --deep --sign - dmg_stage/$APP_NAME

echo "Creating DMG..."
rm -f $DMG_NAME
hdiutil create -volname "$VOL_NAME" -srcfolder dmg_stage -ov -format UDZO $DMG_NAME

echo "Applying Icon to DMG..."
osascript -e 'use framework "Cocoa"' -e 'on run argv' -e 'set theImg to current application'\''s NSImage'\''s alloc()'\''s initWithContentsOfFile:(item 1 of argv)' -e 'current application'\''s NSWorkspace'\''s sharedWorkspace()'\''s setIcon:theImg forFile:(item 2 of argv) options:0' -e 'end run' "AppIcon.icns" "$DMG_NAME"

echo "Done! DMG created at $DMG_NAME"
