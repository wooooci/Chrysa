#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Users/woooci/Applications/Chrysa.app"
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")"

# Self-healing local CLT resource-dir shim inside .build/ (eliminates /tmp dependency & survives macOS reboots)
SHIM_ROOT="$DIR/.build/swift-resource-shim"
CLT_ROOT="/Library/Developer/CommandLineTools"
RESOURCE_ARGS=()
if [[ -f "$CLT_ROOT/usr/include/swift/module.modulemap" && -f "$CLT_ROOT/usr/include/swift/bridging.modulemap" ]]; then
  mkdir -p "$SHIM_ROOT/usr/lib" "$SHIM_ROOT/usr/include/swift"
  ln -sfn "$CLT_ROOT/usr/lib/clang" "$SHIM_ROOT/usr/lib/clang"
  ln -sfn "$CLT_ROOT/usr/lib/swift" "$SHIM_ROOT/usr/lib/swift"
  ln -sfn "$CLT_ROOT/usr/include/swift/bridging" "$SHIM_ROOT/usr/include/swift/bridging"
  ln -sfn "$CLT_ROOT/usr/include/swift/bridging.modulemap" "$SHIM_ROOT/usr/include/swift/bridging.modulemap"
  RESOURCE_ARGS=(-resource-dir "$SHIM_ROOT/usr/lib/swift")
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=("$DIR"/Sources/**/*.swift)

swiftc -parse-as-library -O \
  -sdk "$SDK_PATH" \
  "${RESOURCE_ARGS[@]}" \
  -target arm64-apple-macosx14.0 \
  "${SOURCES[@]}" \
  -o "$APP/Contents/MacOS/Chrysa" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -framework JavaScriptCore \
  -framework CryptoKit \
  -framework WebKit

chmod +x "$APP/Contents/MacOS/Chrysa"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "✅ Built & signed $APP (${#SOURCES[@]} Swift modules)"
