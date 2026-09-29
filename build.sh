#!/bin/zsh
# 构建并安装 LGController.app
#   编译（SwiftPM，不可用时改用 swiftc）→ 手工组装 bundle → 清扩展属性 → 签名 → 安装到 /Applications
#
# 为什么装到 /Applications：本工程位于 iCloud 云盘目录，直接从这里运行会带 iCloud/Finder
# 扩展属性、且路径可能被系统重定位，导致「辅助功能」授权失效（开关是绿的但实际没生效）。
# 安装到本地 /Applications 稳定路径可彻底避免。
#
# 签名身份：默认 ad-hoc（-）。ad-hoc 每次重建 cdhash 都会变，因此重建后需重新授权辅助功能。
# 若钥匙串里存在名为 "LGController Self-Signed"（或沿用旧项目的 "Monitoring Self-Signed"）的自签名代码签名证书，则自动改用它——
# 这样设计器名（Designated Requirement）稳定，重建后无需再次授权。（见 setup-codesign-identity.sh）
set -e
cd "$(dirname "$0")"

# 编译：优先用 SwiftPM（swift build）。SwiftPM 不能用时（常见于命令行工具升级不完整——
# 编译 Package.swift 报 no such module 'PackageDescription'），改用 swiftc 直接编译全部源码：
# 本项目只有一个模块、没有任何依赖，两种方式产物相同。设 LGC_USE_SWIFTC=1 可强制走 swiftc。
BIN=".build/release/LGController"
if [ -z "$LGC_USE_SWIFTC" ] && swift package describe >/dev/null 2>&1; then
  echo "▸ swift build -c release"
  swift build -c release
else
  if [ -z "$LGC_USE_SWIFTC" ]; then
    echo "▸ SwiftPM 不可用（Package.swift 编译失败），改用 swiftc 直接编译"
  fi
  BIN=".build/swiftc/LGController"
  mkdir -p "$(dirname "$BIN")"
  TARGET="$(uname -m)-apple-macos12.0" # 与 Package.swift 的最低系统一致；只编本机架构
  echo "▸ swiftc -O -target $TARGET（首次可能要几分钟：编译器要先为本机重建系统模块缓存）"
  swiftc -O -wmo -swift-version 5 -module-name LGController -target "$TARGET" \
    Sources/LGController/*.swift -o "$BIN"
fi

APP="build/LGController.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LGController"
cp Info.plist "$APP/Contents/Info.plist"

# App 图标（emoji 生成，见 makeicon.swift）。缺失则现场生成一个默认的
if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ 未找到 Resources/AppIcon.icns，用默认 emoji 生成"
  swift makeicon.swift "☀️" Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 选择签名身份
IDENTITY="-"
IDENTITY_DESC="ad-hoc（重建后需重新授权辅助功能）"
# 用 find-identity -p codesigning（不加 -v）：自签名证书未被信任、-v 会过滤掉，但可正常签名
for CANDIDATE in "LGController Self-Signed" "Monitoring Self-Signed"; do
  if security find-identity -p codesigning 2>/dev/null | grep -q "$CANDIDATE"; then
    IDENTITY="$CANDIDATE"
    IDENTITY_DESC="自签名证书「$CANDIDATE」（重建后无需重新授权）"
    break
  fi
done

sign() { # $1 = bundle 路径
  xattr -cr "$1"                                   # 清 iCloud/Finder 扩展属性，否则 codesign 报 detritus
  codesign --force --sign "$IDENTITY" --identifier com.toyzcool.LGController "$1"
}

echo "▸ 签名（$IDENTITY_DESC）"
sign "$APP"

DEST="/Applications/LGController.app"
echo "▸ 安装到 $DEST"
# 若正在运行则先退出，避免覆盖时文件占用
osascript -e 'quit app "LGController"' 2>/dev/null || true
pkill -x LGController 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$APP" "$DEST"
sign "$DEST"                                       # 复制后再签一次，确保最终路径签名干净
codesign --verify --strict "$DEST" && echo "  签名校验通过"

echo ""
echo "✅ 已安装并签名: $DEST"
echo "   启动:  open \"$DEST\""
if [ "$IDENTITY" = "-" ]; then
  echo "   注意:  ad-hoc 签名——若重建后辅助功能失效，运行:"
  echo "          tccutil reset Accessibility com.toyzcool.LGController   然后重新授权"
  echo "   想一劳永逸免去重新授权：运行 ./setup-codesign-identity.sh 建一个自签名证书"
fi
