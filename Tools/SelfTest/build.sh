#!/bin/bash
# 编译自动测试程序：build/selftest/CopiSelfTest.app，以及它用的假 sudo（build/selftest/fakesudo/sudo）。
# SIGN_IDENTITY：签名用的证书（默认 ad-hoc）。本机反复运行时用固定的证书，辅助功能授权在重新编译后仍然有效
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Tools/SelfTest"
OUT="$ROOT/build/selftest"
APP="$OUT/CopiSelfTest.app"

mkdir -p "$APP/Contents/MacOS" "$OUT/fakesudo"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
swiftc -O "$SRC/Sources/main.swift" "$SRC/Sources/extras.swift" "$SRC/Sources/matrix.swift" -o "$APP/Contents/MacOS/CopiSelfTest"
swiftc -O "$SRC/Sources/fakesudo.swift" -o "$OUT/fakesudo/sudo"
codesign --force -s "${SIGN_IDENTITY:--}" "$APP"
codesign --force -s - "$OUT/fakesudo/sudo"
echo "built $APP"
