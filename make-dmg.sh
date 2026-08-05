#!/bin/bash
# 把 build/Namonaki.app 装进一个可以拖进「应用程序」的 dmg。
# 用法：./make-dmg.sh <输出路径.dmg>
set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:?用法: ./make-dmg.sh <输出路径.dmg>}"
APP="build/Namonaki.app"

[ -d "$APP" ] || { echo "没有 $APP，先跑 ./build.sh" >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
# 挂载后左边是 app、右边是「应用程序」，拖过去就装好了
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create \
    -volname "Namonaki" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -quiet \
    "$OUT"

echo "打包完成：$OUT"
