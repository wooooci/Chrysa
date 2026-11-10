#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Users/woooci/Applications/Chrysa.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -resource-dir /tmp/swift_root/usr/lib/swift \
  -target arm64-apple-macosx14.0 \
  "$DIR"/Sources/Models/*.swift \
  "$DIR"/Sources/ViewModels/*.swift \
  "$DIR"/Sources/Services/*.swift \
  "$DIR"/Sources/Views/*.swift \
  "$DIR"/Sources/App/*.swift \
  -o "$APP/Contents/MacOS/Chrysa" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "✅ Built & signed $APP"
