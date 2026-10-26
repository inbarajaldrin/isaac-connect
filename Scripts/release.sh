#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, package, and publish a GitHub Release.
#
# Usage: Scripts/release.sh <tag>            e.g. Scripts/release.sh v0.1.0
#        Scripts/release.sh <tag> --no-upload   (build + notarize, skip gh release)
#
# Prereqs (one-time):
#   1. Developer ID Application cert in your keychain:
#      Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸ "+" ▸ Developer ID Application
#   2. Stored notarization credentials:
#      xcrun notarytool store-credentials isaac-connect-notary \
#        --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
#      (app-specific password: appleid.apple.com ▸ Sign-In & Security ▸ App-Specific Passwords)
#   3. gh CLI authenticated (gh auth status) for the release-upload step.
set -euo pipefail
cd "$(dirname "$0")/.."      # repo root (this script lives in Scripts/)

TAG="${1:?usage: Scripts/release.sh <tag>  e.g. v0.1.0}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "ERROR: use a version tag such as v0.1.0" >&2
  exit 1
fi
VERSION="${TAG#v}"          # strip leading v for CFBundleShortVersionString
UPLOAD=1
[ "${2:-}" = "--no-upload" ] && UPLOAD=0
if [ $# -gt 2 ] || { [ $# -eq 2 ] && [ "$2" != "--no-upload" ]; }; then
  echo "ERROR: usage: Scripts/release.sh <tag> [--no-upload]" >&2
  exit 1
fi

APP="Isaac Connect.app"
PROFILE="${NOTARY_PROFILE:-isaac-connect-notary}"
RELEASE_COMMIT="$(git rev-parse --verify HEAD)"
if [ "$(git branch --show-current)" != "main" ] || [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: release from a clean, reviewed main commit." >&2
  exit 1
fi
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
  echo "ERROR: a Developer ID Application certificate is required for distribution." >&2
  exit 1
fi
if [ "$UPLOAD" = "1" ]; then
  # Check the exact source commit is already on this repository before notarizing.
  RELEASE_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  gh api "repos/$RELEASE_REPO/commits/$RELEASE_COMMIT" --jq .sha >/dev/null
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists; choose a new version." >&2
    exit 1
  fi
fi

# Build + sign with this release's version. build.sh prefers Developer ID automatically.
SIGN_ID="$SIGN_ID" VERSION="$VERSION" BUILD="${BUILD:-1}" ./Scripts/build.sh

# Distribution requires a real Developer ID signature, not Apple Development.
if ! codesign -dvvv "$APP" 2>&1 | grep -q "Developer ID Application"; then
  echo "ERROR: '$APP' is not Developer ID signed."
  echo "Create the cert (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + Developer ID Application) and re-run."
  exit 1
fi
codesign --verify --deep --strict "$APP"
RELEASE_ARCH="$(lipo -archs "$APP/Contents/MacOS/IsaacConnect")"
case "$RELEASE_ARCH" in
  arm64|x86_64) ;;
  *) echo "ERROR: unexpected release architecture: $RELEASE_ARCH" >&2; exit 1 ;;
esac
ASSET="IsaacConnect-macos-${RELEASE_ARCH}-${TAG}.zip"

echo "Zipping for notarization…"
rm -f "$ASSET"
ditto -c -k --keepParent "$APP" "$ASSET"

echo "Submitting to Apple notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ASSET" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Verifying Gatekeeper acceptance…"
spctl --assess --type execute --verbose=2 "$APP"

# Repackage the stapled app so the downloaded zip carries the ticket.
rm -f "$ASSET"
ditto -c -k --keepParent "$APP" "$ASSET"
shasum -a 256 "$ASSET" > "${ASSET}.sha256"

if [ "$UPLOAD" = "1" ]; then
  echo "Publishing GitHub Release $TAG…"
  gh release create "$TAG" "$ASSET" "${ASSET}.sha256" \
    --target "$RELEASE_COMMIT" \
    --title "Isaac Connect macOS $TAG" \
    --notes "Desktop viewer for NVIDIA Isaac Sim and Isaac Lab with remote launch and control features. macOS $RELEASE_ARCH $TAG. Notarized; download $ASSET. Third-party terms: https://github.com/$RELEASE_REPO/blob/$RELEASE_COMMIT/THIRD_PARTY_NOTICES.md"
  echo "Done → published $TAG with $ASSET (+ .sha256)"
else
  echo "Done → $ASSET (+ .sha256), notarized + stapled. Skipped GitHub upload (--no-upload)."
fi
