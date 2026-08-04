#!/bin/bash
# 编译并打包成 Namonaki.app，放在项目根目录下的 build/ 里
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Namonaki.app"

# 日常开发只编当前架构，快一倍。分发要 --universal，否则另一种 CPU 打不开。
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/Namonaki"
else
    swift build -c release
    BIN=".build/release/Namonaki"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Namonaki"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ThirdPartyNotices.md "$APP/Contents/Resources/ThirdPartyNotices.md"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ ! -f Resources/Renderer/index.html ]; then
    echo "缺少 Resources/Renderer，先在 web/ 里 bun run build" >&2
    exit 1
fi
cp -R Resources/Renderer "$APP/Contents/Resources/Renderer"

# 本地自签名，免得 Gatekeeper 每次拦
codesign --force --deep --sign - "$APP"

echo "打包完成：$APP"
