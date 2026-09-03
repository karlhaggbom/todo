#!/bin/bash
# Build Todo.app bundle from the SPM executable.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
BUILD_DIR=".build"
APP_DIR="Todo.app"
CONTENTS="$APP_DIR/Contents"

swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/TodoApp"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/Todo"

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Todo</string>
    <key>CFBundleIdentifier</key><string>com.local.todo</string>
    <key>CFBundleName</key><string>Todo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict>
</plist>
EOF

# Ad-hoc codesign so the app launches from Finder without Gatekeeper friction.
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"