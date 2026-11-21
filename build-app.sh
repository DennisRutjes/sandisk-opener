#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="SanDisk Opener.app"
BIN="$APP/Contents/MacOS/SanDiskOpener"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling SwiftUI app..."
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -o "$BIN" app/SanDiskOpener.swift

echo "Bundling the verified unlock CLI..."
cp sandisk-unlock "$APP/Contents/Resources/sandisk-unlock"
chmod +x "$APP/Contents/Resources/sandisk-unlock"

cp app/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f app/AppIcon.icns ]]; then
  cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Signing (ad-hoc, local use)..."
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "codesign failed; the app may still run locally." >&2
}

echo "Built: $(pwd)/$APP"
file "$BIN"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Format" | head -3 || true
