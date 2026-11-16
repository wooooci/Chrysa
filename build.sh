#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${CHRYSA_APP_PATH:-$HOME/Applications/Chrysa.app}"
ASSET_APP="${CHRYSA_ASSET_APP:-$HOME/Applications/Chrysa.app}"

cd "$DIR"
./scripts/swiftpm.sh build -c release --product Chrysa
BIN_DIR="$(./scripts/swiftpm.sh build -c release --show-bin-path)"

# Stage the complete bundle before replacing the installed copy.
mkdir -p "$(dirname "$APP")"
STAGING="$(mktemp -d "$(dirname "$APP")/.chrysa-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/Chrysa.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# Runtime assets are distributed with the app separately from the Swift sources.
# Prefer the destination's existing assets when updating it.
if [[ -z "${CHRYSA_ASSET_APP:-}" && -f "$APP/Contents/MacOS/sf-dl" ]]; then
  ASSET_APP="$APP"
fi
if [[ -d "$ASSET_APP/Contents/Resources" ]]; then
  /usr/bin/ditto "$ASSET_APP/Contents/Resources" "$BUNDLE/Contents/Resources"
fi
if [[ -f "$ASSET_APP/Contents/MacOS/sf-dl" ]]; then
  /usr/bin/ditto "$ASSET_APP/Contents/MacOS/sf-dl" "$BUNDLE/Contents/MacOS/sf-dl"
fi

cp "$DIR/packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
if [[ -n "${CHRYSA_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$CHRYSA_VERSION" "$BUNDLE/Contents/Info.plist"
fi
BUILD_NUMBER="${CHRYSA_BUILD_NUMBER:-$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUNDLE/Contents/Info.plist")"
cp "$BIN_DIR/Chrysa" "$BUNDLE/Contents/MacOS/Chrysa"
chmod +x "$BUNDLE/Contents/MacOS/Chrysa"
xattr -cr "$BUNDLE"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

# Keep the previous bundle available until the new bundle has been published.
if [[ -e "$APP" ]]; then
  mv "$APP" "$STAGING/Previous.app"
fi
if ! mv "$BUNDLE" "$APP"; then
  if [[ -e "$STAGING/Previous.app" ]]; then
    mv "$STAGING/Previous.app" "$APP"
  fi
  exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Built and signed $APP (v${SHORT_VERSION} build ${BUILD_NUMBER})"
echo "Runtime asset source: $ASSET_APP"
