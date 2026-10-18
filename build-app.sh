#!/bin/zsh
# Builds LampBar.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/LampBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LampBar "$APP/Contents/MacOS/LampBar"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Sign with a stable identity when available so Keychain "Always Allow" survives rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/LampBar.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/LampBar.app"
fi
