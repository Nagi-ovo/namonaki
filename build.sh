#!/bin/bash
# 编译并打包成 Namonaki.app，放在项目根目录下的 build/ 里
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Namonaki.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Namonaki "$APP/Contents/MacOS/Namonaki"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 本地自签名，免得 Gatekeeper 每次拦
codesign --force --deep --sign - "$APP"

echo "打包完成：$APP"
