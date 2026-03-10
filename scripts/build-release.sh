#!/bin/bash
set -euo pipefail

APP_NAME="AppMixer"
VERSION="${1:-1.0.0}"
BUILD_DIR="$(pwd)/.build/release"
APP_BUNDLE="$(pwd)/dist/${APP_NAME}.app"
DMG_PATH="$(pwd)/dist/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME} v${VERSION}"

swift build -c release 2>&1

echo "==> Creating app bundle"

rm -rf dist
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.bbioren.appmixer</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AppMixer needs audio access to control per-app volume levels.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AppMixer needs screen capture access to tap into app audio streams.</string>
</dict>
</plist>
PLIST

echo "==> App bundle created at ${APP_BUNDLE}"

echo "==> Creating DMG"

rm -f "${DMG_PATH}"
TEMP_DMG="$(mktemp -d)"
cp -R "${APP_BUNDLE}" "${TEMP_DMG}/"
ln -s /Applications "${TEMP_DMG}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${TEMP_DMG}" \
    -ov -format UDZO \
    "${DMG_PATH}" 2>&1

rm -rf "${TEMP_DMG}"

echo "==> DMG created at ${DMG_PATH}"
echo "==> Done!"
