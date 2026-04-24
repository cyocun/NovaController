#!/usr/bin/env bash
# NovaController リリーススクリプト
#
# Usage:
#   scripts/release.sh <version>    e.g. scripts/release.sh 0.1.1
#
# 処理:
#   1. Release build
#   2. .app を .zip に圧縮 (ditto)
#   3. Sparkle の sign_update で EdDSA 署名
#   4. GitHub Release 作成 & zip アセット添付
#   5. docs/appcast.xml にエントリ追加
#
# 前提:
#   - Sparkle の EdDSA 秘密鍵が Keychain に登録済み (generate_keys で作成)
#   - gh CLI がログイン済み
#   - バージョン番号は project.pbxproj の MARKETING_VERSION に合わせる

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <version>   # e.g. $0 0.1.1" >&2
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
PROJECT="$REPO_ROOT/NovaController/NovaController.xcodeproj"
SCHEME="NovaController"
APP_NAME="NovaController"
ZIP_NAME="${APP_NAME}-${TAG}-macOS.zip"

# Sparkle CLI tools (SPM 成果物にバンドルされている)
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/NovaController-etbqxnqvoegqekeapnuhotcqtemj/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
    echo "ERROR: sign_update not found at $SIGN_UPDATE" >&2
    echo "Run the project once in Xcode to fetch Sparkle SPM artifacts." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

echo "==> Release build ($TAG)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    MARKETING_VERSION="$VERSION" \
    build | tail -3

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

echo "==> Packaging $ZIP_NAME"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Signing update (EdDSA)"
SIGN_OUTPUT=$("$SIGN_UPDATE" "$ZIP_PATH")
echo "$SIGN_OUTPUT"

# sign_update の出力: `sparkle:edSignature="..." length="..."`
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ZIP_LENGTH=$(stat -f%z "$ZIP_PATH")
PUB_DATE=$(LC_TIME=C date -u "+%a, %d %b %Y %H:%M:%S +0000")   # RFC 822, Sparkle 必須の英語ロケール
REPO_URL="https://github.com/cyocun/novaCLT4Mac"
DOWNLOAD_URL="${REPO_URL}/releases/download/${TAG}/${ZIP_NAME}"

echo "==> Creating GitHub release $TAG"
git tag -f "$TAG"
git push origin "$TAG" --force
gh release create "$TAG" "$ZIP_PATH" \
    --title "$TAG" \
    --notes "NovaController $TAG\n\n詳細は CHANGELOG や README を参照。" \
    --prerelease || gh release upload "$TAG" "$ZIP_PATH" --clobber

echo "==> appcast.xml 用エントリ"
cat <<EOF

<item>
    <title>Version ${VERSION}</title>
    <pubDate>${PUB_DATE}</pubDate>
    <sparkle:version>${VERSION}</sparkle:version>
    <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure
        url="${DOWNLOAD_URL}"
        length="${ZIP_LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}"/>
</item>

EOF
echo "上記を docs/appcast.xml の <channel> 内に追加して commit & push してください。"
echo "done."
