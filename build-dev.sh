#!/bin/bash
# 開発用：コマンドラインの実行ファイルだけ作る
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -target arm64-apple-macos14.0 -o build/mushi-dev src/*.swift -framework AppKit -framework Metal -framework MetalPerformanceShaders -framework QuartzCore -framework Carbon 2>&1 | grep -v "deprecated" | grep -E "error|warning" || true
cp src/Shaders.metal build/
