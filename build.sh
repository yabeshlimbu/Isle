#!/bin/bash
# Builds Isle.app.  Usage:
#   ./build.sh            build into ./build/Isle.app
#   ./build.sh install    build, copy to /Applications and launch
# Optional: SIGN_ID="My Cert" ./build.sh   (sign with your own self-signed
# certificate so macOS remembers permissions between rebuilds)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Isle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Isle "$APP/Contents/MacOS/Isle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Isle || true
    rm -rf /Applications/Isle.app
    cp -R "$APP" /Applications/
    open /Applications/Isle.app
    echo "Installed to /Applications/Isle.app"
fi
