#!/bin/bash
# This target has no Flutter dependency and can be retried independently.
set -euo pipefail
ARCH=${1:?Usage: build_helper.sh arm64\|x64 output-directory}
DESTINATION=${2:?Missing output directory}
case "$ARCH" in arm64) TARGET=arm64 ;; x64) TARGET=x86_64 ;; *) exit 2 ;; esac
export MACOSX_DEPLOYMENT_TARGET=12.0
[[ "$(xcodebuild -version)" == $'Xcode 16.4\nBuild version 16F6' ]] || { echo 'Xcode 16.4 (16F6) is required.' >&2; exit 1; }
BUILD="build/macos-helper/$ARCH"
mkdir -p "$DESTINATION"
swift test --package-path macos/NetworkService --scratch-path "$BUILD"
swift run --package-path macos/NetworkService --scratch-path "$BUILD" keqdis-network-tests
swift build --package-path macos/NetworkService --scratch-path "$BUILD" -c release --arch "$TARGET" --product keqdis-network-service
BIN=$(swift build --package-path macos/NetworkService --scratch-path "$BUILD" -c release --arch "$TARGET" --show-bin-path)
cp "$BIN/keqdis-network-service" "$DESTINATION/keqdis-network-service"
chmod 755 "$DESTINATION/keqdis-network-service"
"$DESTINATION/keqdis-network-service" --self-check
