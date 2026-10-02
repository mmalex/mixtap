#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/objects build/ModuleCache
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
APP="build/MixTap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang++ -std=c++17 -O2 -g -fobjc-arc -Wall -Wextra \
  -isysroot "$SDK" -mmacosx-version-min=14.2 \
  -fmodules-cache-path="$PWD/build/ModuleCache" \
  -c Sources/Audio/AudioBridge.mm -o build/objects/AudioBridge.o
xcrun swiftc -parse-as-library -swift-version 5 -O -g -sdk "$SDK" -target "$ARCH-apple-macosx14.2" \
  -module-cache-path "$PWD/build/ModuleCache" \
  -import-objc-header Sources/Audio/AudioBridge.h \
  Sources/App/*.swift build/objects/AudioBridge.o \
  -framework Cocoa -framework SwiftUI -framework AVFoundation -framework CoreAudio \
  -framework AudioToolbox -lc++ -o "$APP/Contents/MacOS/MixTap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Local development only. Developer ID distribution and notarization come later.
codesign --force --sign "${MIXTAP_SIGNING_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
printf 'Built %s/%s\n' "$PWD" "$APP"
