#!/bin/sh
# 编译 DouYinKeepPlay.dylib（零 Theos：xcrun clang → codesign）
#
# 用法：sh devkit/build.sh <arch> <version>
set -eu

ARCH="${1:?用法: build.sh <arch> <version>}"
VER="${2:?用法: build.sh <arch> <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="DouYinKeepPlay"
BUILDDIR="$ROOT/.build"
TRIPLE="arm64-apple-ios14.0"

rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"

echo "→ 编译 $NAME ($ARCH) version=$VER"

# ★ 只编 arm64：宿主是抖音 App，App Store 分发的 App 一律 arm64。
#   dylib 在 arm64 与 arm64e 两个包里字节相同，包标签只影响 Sileo 是否愿意装。
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -miphoneos-version-min=14.0 \
    -target "$TRIPLE" \
    -dynamiclib \
    -fobjc-arc \
    -fobjc-link-runtime \
    -framework Foundation \
    -framework UIKit \
    -framework AVFoundation \
    -framework MediaPlayer \
    -framework CoreGraphics \
    -headerpad_max_install_names \
    -install_name "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib" \
    -o "$BUILDDIR/$NAME.dylib" \
    "$ROOT/main.m"

# 自签（RootHide/ellekit 要求 dylib 必须带 ad-hoc 签名）
codesign --force --sign - "$BUILDDIR/$NAME.dylib"

echo "→ 产物闸门"
# 1) 必须是 arm64 切片
lipo -info "$BUILDDIR/$NAME.dylib" | grep -q arm64
echo "  ✓ arm64 切片"
# 2) filetype 必须是 MH_DYLIB(6)，不能是 MH_BUNDLE(8)
#    ★ 用 od 直接读 mach_header_64 偏移 12（4 字节小端），
#      不用 `otool -l | awk '/filetype/'` —— 不同 Xcode 版本 otool 的
#      输出空白/字段位置会变（实测 Xcode 26.6 上 awk 取到空值 → 假红）。
DTYPE=$(od -An -tu4 -j12 -N4 "$BUILDDIR/$NAME.dylib" | tr -d ' ')
if [ "$DTYPE" != "6" ]; then
    echo "  ✗ Mach-O 类型 $DTYPE != 6（MH_DYLIB）"; exit 1
fi
echo "  ✓ filetype=6 (MH_DYLIB)"
# 3) 必须有 LC_CODE_SIGNATURE（RootHide 加载前提之一）
otool -l "$BUILDDIR/$NAME.dylib" | grep -q LC_CODE_SIGNATURE
echo "  ✓ LC_CODE_SIGNATURE 存在"
# 4) install_name 必须指向 .jbroot 路径（RootHide 加载前提之二）
otool -l "$BUILDDIR/$NAME.dylib" | grep -q "\.jbroot/Library/MobileSubstrate"
echo "  ✓ install_name 指向 .jbroot"

echo "→ 构建完成：$BUILDDIR/$NAME.dylib"
ls -l "$BUILDDIR/$NAME.dylib"
