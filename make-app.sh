#!/bin/bash
# Build PostureGuard and assemble a minimal .app bundle so camera permission
# (TCC) is attributed to the app itself instead of the launching terminal.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/PostureGuard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PostureGuard "$APP/Contents/MacOS/PostureGuard"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>PostureGuard</string>
    <key>CFBundleIdentifier</key>       <string>com.chucai.posture-guard</string>
    <key>CFBundleName</key>             <string>PostureGuard</string>
    <key>CFBundleDisplayName</key>      <string>坐姿卫士</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSCameraUsageDescription</key> <string>用摄像头检测人脸朝向，结合屏幕开合角度监测低头坐姿。画面只在本机实时分析，不保存、不上传。</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "✅ 已生成 $APP"
echo "   启动:     open $APP"
echo "   开机自启: 系统设置 → 通用 → 登录项 中添加"
