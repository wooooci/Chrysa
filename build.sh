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
echo "Built and signed $APP"
echo "Runtime asset source: $ASSET_APP"
