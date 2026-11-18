#!/bin/bash
# 虫カーソルを終了する（ふつうのカーソルに戻る）
osascript -e 'tell application id "com.neuwonka.mushicursor" to quit' >/dev/null 2>&1
sleep 0.8
pkill -x MushiCursor 2>/dev/null
echo "終了しました。"
sleep 1
osascript -e 'tell application "Terminal" to close (every window whose name contains "おわる")' >/dev/null 2>&1 &
exit 0
