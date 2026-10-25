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
swiftc -O -o "$APP/Contents/MacOS/$BIN" Sources/*.swift

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
	<key>CFBundleShortVersionString</key><string>0.22</string>
	<key>CFBundleVersion</key><string>22</string>
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
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "  (签名跳过)"

# 必须标记为 Bundle，否则 Finder 不显示图标
SetFile -a B "$APP" 2>/dev/null || echo "  (SetFile 跳过)"

echo "✓ 完成：$APP"
du -sh "$APP"

# ./build.sh --install 会直接替换 /Applications 里的正式版本
if [ "${1:-}" = "--install" ]; then
  echo "▸ 安装到 /Applications"
  pkill -f "MacOS/LectureGen" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/讲义生成.app"
  cp -R "$APP" /Applications/
  # cp -R 后安装副本的 Finder bundle 标记可能丢失（Finder 图标变通用图标，
  # 但 Dock 仍能从 Info.plist 读到图标），所以在安装副本上再标一次并 touch
  SetFile -a B "/Applications/讲义生成.app" 2>/dev/null || echo "  (安装副本 SetFile 跳过)"
  touch "/Applications/讲义生成.app"
  echo "✓ 已安装：/Applications/讲义生成.app"
  open "/Applications/讲义生成.app"
fi
