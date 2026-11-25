#!/usr/bin/env bash
set -euo pipefail

REPO="wooooci/Chrysa"
APP_NAME="Chrysa.app"
DEFAULT_VERSION="0.9.0"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：Chrysa 仅支持 macOS。" >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "错误：当前 Release 仅支持 Apple Silicon (arm64) Mac，检测到架构为 $ARCH。" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chrysa-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Resolve target version via releases.atom (no GitHub API rate limit, works for prereleases,
# and avoids requiring Xcode Command Line Tools / python3 on stock macOS).
if [[ -n "${CHRYSA_VERSION:-}" ]]; then
  VERSION="${CHRYSA_VERSION#v}"
  TAG="v${VERSION}"
else
  echo "正在获取 Chrysa 最新版本..."
  ATOM_XML="$(curl -fsSL -A "Chrysa-Installer" "https://github.com/${REPO}/releases.atom" 2>/dev/null || true)"
  DETECTED_TAG="$(
    printf '%s\n' "$ATOM_XML" \
      | sed -n 's|.*href="https://github.com/'"${REPO}"'/releases/tag/\([^"]*\)".*|\1|p' \
      | head -n 1
  )"
  if [[ -n "$DETECTED_TAG" ]]; then
    TAG="$DETECTED_TAG"
    VERSION="${TAG#v}"
  else
    VERSION="$DEFAULT_VERSION"
    TAG="v${VERSION}"
    echo "提示：未能拉取版本列表，回退安装默认版本 ${TAG}。"
  fi
fi

ZIP_NAME="Chrysa-${VERSION}-macos-arm64.zip"
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}"
SHA_URL="${ZIP_URL}.sha256"

ZIP_PATH="$TMP_DIR/$ZIP_NAME"
echo "正在下载 ${TAG} (${ZIP_NAME})..."
curl -fL --progress-bar -A "Chrysa-Installer" "$ZIP_URL" -o "$ZIP_PATH"

SHA_PATH="$TMP_DIR/${ZIP_NAME}.sha256"
if curl -fsSL -A "Chrysa-Installer" "$SHA_URL" -o "$SHA_PATH"; then
  echo "正在校验 SHA-256..."
  (cd "$TMP_DIR" && /usr/bin/shasum -a 256 -c "$SHA_PATH")
fi

EXTRACT_DIR="$TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
echo "正在解压 ${APP_NAME}..."
/usr/bin/ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"

STAGED_APP="$EXTRACT_DIR/$APP_NAME"
if [[ ! -d "$STAGED_APP" ]]; then
  echo "错误：压缩包中未找到 ${APP_NAME}。" >&2
  exit 1
fi

/usr/bin/xattr -cr "$STAGED_APP" || true
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

if [[ -n "${CHRYSA_INSTALL_DIR:-}" ]]; then
  INSTALL_DIR="$CHRYSA_INSTALL_DIR"
elif [[ -w "/Applications" ]]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
fi

mkdir -p "$INSTALL_DIR"
TARGET_APP="${INSTALL_DIR%/}/${APP_NAME}"
BACKUP_APP="$TMP_DIR/Previous-${APP_NAME}"

if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! mv "$STAGED_APP" "$TARGET_APP"; then
  if [[ -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP"
  fi
  echo "错误：无法安装到 ${TARGET_APP}。" >&2
  exit 1
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1 || true

echo ""
echo "✓ Chrysa ${TAG} 已安装至 ${TARGET_APP}"
echo "可直接从「应用程序」打开，或运行：open \"$TARGET_APP\""
