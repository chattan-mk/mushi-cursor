#!/bin/bash
# 虫カーソルを起動する（初回やソースを変えた時は自動でビルド）
cd "$(dirname "$0")"
APP="$HOME/Applications/虫カーソル.app"
if [ ! -d "$APP" ] || [ -n "$(find src -newer "$APP/Contents/MacOS/MushiCursor" -print -quit 2>/dev/null)" ]; then
  echo "ビルドしています…"
  ./build.sh || { echo "ビルドに失敗しました"; read -n1; exit 1; }
fi
open "$APP"
echo "起動しました。メニューバーのクモのアイコンから設定できます。"
echo "ふつうのカーソルに戻す: ⌃⌥⌘S（もう一度押すと虫が戻る）"
sleep 1.5
osascript -e 'tell application "Terminal" to close (every window whose name contains "はじめる")' >/dev/null 2>&1 &
exit 0
