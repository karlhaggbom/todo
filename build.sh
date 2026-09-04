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

# Sign with the stable local identity when present ("Todo Dev", created
# once via openssl + `security import`; see README) so the Keychain sees
# the same app every build — ad-hoc signatures change every build, which
# makes the Keychain prompt for the login password on each token access.
if security find-identity -v -p codesigning | grep -q '"Todo Dev"'; then
    codesign --force --sign "Todo Dev" "$APP_DIR"
else
    codesign --force --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"