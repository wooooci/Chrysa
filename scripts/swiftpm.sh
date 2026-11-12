#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="$(xcrun --find swift)"
TOOLCHAIN="${SWIFT_BIN%/bin/swift}"
SHIM="$DIR/.build/toolchain-shim"

# Some CLT installations retain private Swift 5.10 interfaces beside Swift 6 libraries.
# Copy only the manifest APIs locally and prefer the matching public interface there.
MANIFEST_API="$TOOLCHAIN/lib/swift/pm/ManifestAPI"
if [[ -d "$MANIFEST_API" ]]; then
  mkdir -p "$SHIM/pm"
  /usr/bin/ditto "$MANIFEST_API" "$SHIM/pm/ManifestAPI"
  for private in "$SHIM"/pm/ManifestAPI/**/*.private.swiftinterface(N); do
    public="${private%.private.swiftinterface}.swiftinterface"
    if [[ -f "$public" ]] && ! diff -q <(head -n 2 "$private") <(head -n 2 "$public") >/dev/null; then
      cp "$public" "$private"
    fi
  done
  export SWIFTPM_CUSTOM_LIBS_DIR="$SHIM/pm"
fi

# Resolve the duplicate Swift bridging module map in affected CLT resource layouts.
RESOURCE_ARGS=()
if [[ -f "$TOOLCHAIN/include/swift/module.modulemap" && -f "$TOOLCHAIN/include/swift/bridging.modulemap" ]]; then
  mkdir -p "$SHIM/usr/lib" "$SHIM/usr/include/swift"
  ln -sfn "$TOOLCHAIN/lib/clang" "$SHIM/usr/lib/clang"
  ln -sfn "$TOOLCHAIN/lib/swift" "$SHIM/usr/lib/swift"
  ln -sfn "$TOOLCHAIN/include/swift/bridging" "$SHIM/usr/include/swift/bridging"
  ln -sfn "$TOOLCHAIN/include/swift/bridging.modulemap" "$SHIM/usr/include/swift/bridging.modulemap"
  RESOURCE_ARGS=(-Xswiftc -resource-dir -Xswiftc "$SHIM/usr/lib/swift")
fi

exec "$SWIFT_BIN" "$@" "${RESOURCE_ARGS[@]}"
