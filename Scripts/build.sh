#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."      # repo root (this script lives in Scripts/)

APP_NAME="IsaacConnect"          # executable name
DISPLAY_NAME="Isaac Connect"     # user-visible bundle name
BUNDLE_ID="io.github.inbarajaldrin.isaac-connect"
VERSION="${VERSION:-0.1.0}"  # CFBundleShortVersionString (release.sh passes the tag)
BUILD="${BUILD:-1}"          # CFBundleVersion (increment per release)
# Prefer a Developer ID Application cert (notarizable distribution); fall back to
# Apple Development (fine for running on your own Macs). Override with SIGN_ID=…
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
echo "Signing identity: $SIGN_ID"

if ! python3 Scripts/import-renderer.py --check; then
  python3 Scripts/import-renderer.py --app "${NVIDIA_CLIENT_APP:-/Applications/Isaac Sim WebRTC Streaming Client.app}"
fi

swift build -c release
BIN=".build/release/${APP_NAME}"

APP="${DISPLAY_NAME}.app"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp LICENSE "${APP}/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "${APP}/Contents/Resources/THIRD_PARTY_NOTICES.md"

# SPM .copy puts the Renderer dir into a resource bundle next to the binary.
# Flatten it into Contents/Resources/Renderer so Bundle.main.resourceURL finds it.
RESBUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "${RESBUNDLE}/Renderer" ]; then
  cp -R "${RESBUNDLE}/Renderer" "${APP}/Contents/Resources/Renderer"
elif [ -d "${RESBUNDLE}/Contents/Resources/Renderer" ]; then
  cp -R "${RESBUNDLE}/Contents/Resources/Renderer" "${APP}/Contents/Resources/Renderer"
else
  echo "ERROR: could not find bundled Renderer dir under ${RESBUNDLE}"; find .build/release -maxdepth 3 -name Renderer -type d; exit 1
fi

# App icon (original artwork — see AppIcon.icns).
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "WARNING: AppIcon.icns not found — app will use the generic icon"
fi

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>        <string>${DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>            <string>${BUILD}</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>     <string>14.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>LSApplicationCategoryType</key>  <string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key>   <string>© 2026 Aldrin Inbaraj. Third-party licenses apply.</string>

  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>             <true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key> <true/>
    <key>NSAllowsLocalNetworking</key>            <true/>
  </dict>

</dict>
</plist>
EOF

codesign --force --options runtime --timestamp --entitlements entitlements.plist --sign "$SIGN_ID" "${APP}/Contents/MacOS/${APP_NAME}"
codesign --force --options runtime --timestamp --entitlements entitlements.plist --sign "$SIGN_ID" "$APP"

echo "Built and signed ${APP}"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier|Authority' | head -2 || true
