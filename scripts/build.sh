#!/bin/bash
# Compile and sign outside the repository. Uses the existing local certificate;
# never generates a replacement or falls back to an ad-hoc signature.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_identity="659A2CD838DF7ADCB88F313BDE6572A223C4923C"
bundle_identifier="com.local.MouseYBoost"
requirement="=identifier \"$bundle_identifier\" and certificate root = H\"$signing_identity\""

if ! security find-identity -v -p codesigning | /usr/bin/grep -q "$signing_identity"; then
    echo "Missing fixed signing identity: $signing_identity" >&2
    echo "Restore the original certificate and private key before building." >&2
    exit 1
fi

build_dir="$(mktemp -d /private/tmp/MouseYBoost-build.XXXXXX)"
app_path="$build_dir/MouseYBoost.app"
mkdir -p "$app_path/Contents/MacOS" "$build_dir/ModuleCache"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
target="$(uname -m)-apple-macosx13.0"

# All compiler intermediate files and module caches stay in the temporary directory.
xcrun clang -O2 -Wall -Wextra -Werror -target "$target" -isysroot "$sdk_path" \
    -c "$repo_dir/Sources/DeviceBridge.c" -o "$build_dir/DeviceBridge.o"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$target" \
    -sdk "$sdk_path" -module-cache-path "$build_dir/ModuleCache" \
    -import-objc-header "$repo_dir/Sources/DeviceBridge.h" \
    "$repo_dir/Sources/Preferences.swift" \
    "$repo_dir/Sources/MouseEngine.swift" \
    "$repo_dir/Sources/LoginItem.swift" \
    "$repo_dir/Sources/SettingsWindow.swift" \
    "$repo_dir/Sources/main.swift" \
    "$build_dir/DeviceBridge.o" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics \
    -framework IOKit -framework ServiceManagement \
    -o "$app_path/Contents/MacOS/MouseYBoost"
cp "$repo_dir/Info.plist" "$app_path/Contents/Info.plist"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign "$signing_identity" --timestamp=none \
    --identifier "$bundle_identifier" "$app_path"
codesign --verify --deep --strict -R "$requirement" "$app_path"
echo "Signed application: $app_path"
