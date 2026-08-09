#!/usr/bin/env bash
# Wrap the lookit binary into a real .app.
#
# SPM cannot produce a bundle, and lookit needs one: LSUIElement lives in an
# Info.plist, Login Items only accepts apps, and a stable bundle identity is what
# any future permission grant would attach to.
#
#     ./scripts/bundle.sh [--release]

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
[[ "${1:-}" == "--release" ]] && CONFIGURATION="release"

echo "building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product lookit

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/lookit"
[[ -x "$BIN" ]] || { echo "no binary at $BIN" >&2; exit 1; }

APP="lookit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/lookit"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>lookit</string>
    <key>CFBundleDisplayName</key>       <string>lookit</string>
    <key>CFBundleExecutable</key>        <string>lookit</string>
    <key>CFBundleIdentifier</key>        <string>dev.lookit.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menubar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not for distribution — it stops macOS treating each rebuild
# as a brand new app, which would otherwise reset anything keyed to identity.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed" >&2

echo "built $APP"
echo "  open $APP                  # run it"
echo "  System Settings > General > Login Items to start it automatically"
