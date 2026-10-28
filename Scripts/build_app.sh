#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="$(grep -m1 'static let fallbackVersion' Sources/PostmanSwift/App/AppInfo.swift | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d)}"
ICON="Assets/AppIcon.icns"

if [ ! -f "$ICON" ]; then
    ./Scripts/build_icon.sh
fi

swift build -c "$CONFIG"

BIN=".build/${CONFIG}/PostmanSwift"
APP="${APP_PATH:-dist/PostmanSwift.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PostmanSwift"
chmod +x "$APP/Contents/MacOS/PostmanSwift"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PostmanSwift</string>
    <key>CFBundleDisplayName</key>
    <string>PostmanSwift</string>
    <key>CFBundleIdentifier</key>
    <string>com.postmanswift.app</string>
    <key>CFBundleExecutable</key>
    <string>PostmanSwift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local-first native API client</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
