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
