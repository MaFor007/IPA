#!/bin/bash
# 在 macOS 上一键构建 TrollStore 可安装的 .tipa
# 用法: bash build.sh
set -e
cd "$(dirname "$0")"

APP_NAME="Bridge"
EXEC_NAME="iPhoneBridge"
OUT="build"

rm -rf "$OUT"
mkdir -p "$OUT/Payload/$APP_NAME.app"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "iOS SDK: $SDK"

xcrun -sdk iphoneos swiftc \
  -target arm64-apple-ios14.0 \
  -sdk "$SDK" \
  -O -wmo \
  Sources/*.swift \
  -o "$OUT/Payload/$APP_NAME.app/$EXEC_NAME" \
  -framework UIKit \
  -framework Foundation \
  -framework Network \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework MediaPlayer

cp Info.plist "$OUT/Payload/$APP_NAME.app/"

if ! command -v ldid >/dev/null 2>&1; then
  echo "安装 ldid ..."
  brew install ldid
fi
ldid -Sentitlements.plist "$OUT/Payload/$APP_NAME.app/$EXEC_NAME"

cd "$OUT"
zip -qry "$APP_NAME.tipa" Payload
echo "构建完成: $(pwd)/$APP_NAME.tipa"
