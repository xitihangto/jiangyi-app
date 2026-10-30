#!/bin/bash
# 构建「讲义生成.app」——纯命令行，不依赖 Xcode 工程
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/讲义生成.app"
BIN="LectureGen"

echo "▸ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译 Swift"
# 自动化会话 / 非交互环境里，swift 驱动会用 sandbox-exec 包一层去起宏插件服务，
# 而沙箱规则应用会被拒，报「SwiftUIMacros ... produced malformed response」，
# SwiftUI 的 @State 就展不开（连带一堆假的「self is immutable」错误）。
# 加 -disable-sandbox 关掉这层包裹即可；老工具链不认这个参数时自动不加，行为与原来一致。
SANDBOX_FLAG=""
if swiftc -disable-sandbox -version >/dev/null 2>&1; then
  SANDBOX_FLAG="-disable-sandbox"
fi
swiftc -O $SANDBOX_FLAG -o "$APP/Contents/MacOS/$BIN" Sources/*.swift

echo "▸ 拷入资源（内置附件 + 图标 + 本地化）"
cp -R Resources/. "$APP/Contents/Resources/"

echo "▸ 拷入 Python 运行时（仅 docx 依赖）"
if [ -d Runtime/python ]; then
  cp -R Runtime/python "$APP/Contents/Resources/python"
  # 去掉随包无用的缓存，减小体积
  find "$APP/Contents/Resources/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
else
  echo "  ⚠️ Runtime/python 缺失，App 将无法执行脚本"
fi

echo "▸ 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>讲义生成</string>
	<key>CFBundleDisplayName</key><string>讲义生成</string>
	<key>CFBundleIdentifier</key><string>com.workbuddy.lecturegen</string>
	<key>CFBundleExecutable</key><string>LectureGen</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.36</string>
	<!-- 故意不写 CFBundleVersion：系统「关于」面板会把它显示成「版本 0.35 (34)」。
	     这个 App 不用 Sparkle、不进 App Store，构建号没有任何用途，
	     更新台和 CI 也都只读 CFBundleShortVersionString。 -->
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>zh-Hans</string>
	</array>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAppleEventsUsageDescription</key><string>需要控制 Safari，把考卷、答案与内置附件填入 DeepSeek 对话框。</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 临时签名"
# 增量构建时 SetFile 写进去的 FinderInfo 会让 codesign 报
# "resource fork, Finder information, or similar detritus not allowed" 并**静默失败**
# —— 一旦跳过，bundle 只剩 linker-signed，Identifier 变成可执行文件名（LectureGen），
# 不再是 Info.plist 里的 com.workbuddy.*，而 UserDefaults 和 WKWebView 的 cookie
# 都是按 Identifier 分域的，后果是「上次选择 / 目录记忆」读不到、登录态丢失。
# 所以先清干净再签，且失败要能看见（不要 2>/dev/null）。
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" || echo "  ⚠️ 签名失败（Identifier 会退化成可执行名，UserDefaults 域跟着变）"

# 这里**故意不设 bundle bit**（以前签名后会跑一句 `SetFile -a B`）。
# 它写的是 com.apple.FinderInfo 扩展属性，只要属性在，签的时候就过不去，
# `codesign --verify --strict` 也一直报 detritus。而且挪到签名前同样无效。
# 其实不需要：`.app` 后缀本身就映射到 com.apple.application-bundle，
# Finder 照样认包、照样显示图标。去掉后 strict 校验干净通过（2026-10-30）。

echo "✓ 完成：$APP"
du -sh "$APP"

# ./build.sh --install 会直接替换 /Applications 里的正式版本
if [ "${1:-}" = "--install" ]; then
  echo "▸ 安装到 /Applications"
  pkill -f "MacOS/LectureGen" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/讲义生成.app"
  cp -R "$APP" /Applications/
  # 以前这里还有一句 `SetFile -a B` 补 bundle 标记，已删除（同签名处，2026-10-30）：
  # .app 后缀足够，加了反而让 strict 校验报 detritus
  touch "/Applications/讲义生成.app"
  echo "✓ 已安装：/Applications/讲义生成.app"
  open "/Applications/讲义生成.app"
fi
