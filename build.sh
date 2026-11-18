#!/bin/bash
# 虫カーソル.app を作って ~/Applications に入れる
set -e
cd "$(dirname "$0")"
NAME="虫カーソル"
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/MushiCursor" src/*.swift \
  -framework AppKit -framework Metal -framework MetalPerformanceShaders -framework QuartzCore -framework Carbon \
  2>&1 | grep -v "deprecated" | grep -E "error|warning" || true
test -x "$APP/Contents/MacOS/MushiCursor"
cp src/Shaders.metal "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.neuwonka.mushicursor</string>
  <key>CFBundleExecutable</key><string>MushiCursor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
mkdir -p "$HOME/Applications"
pkill -x MushiCursor 2>/dev/null && sleep 0.5 || true
rm -rf "$HOME/Applications/$NAME.app"
cp -R "$APP" "$HOME/Applications/"
echo "できました: $HOME/Applications/$NAME.app"
