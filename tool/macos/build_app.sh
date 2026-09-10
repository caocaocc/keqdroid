#!/bin/bash
# Keep app compilation separate from packaging so installer changes reuse it.
set -euo pipefail
ARCH=${1:?Usage: build_app.sh arm64\|x64 output-directory}
DESTINATION=${2:?Missing output directory}
case "$ARCH" in arm64|x64) ;; *) exit 2 ;; esac
export MACOSX_DEPLOYMENT_TARGET=12.0
export COCOAPODS_DISABLE_STATS=true
[[ "$(xcodebuild -version)" == $'Xcode 16.4\nBuild version 16F6' ]] || { echo 'Xcode 16.4 (16F6) is required.' >&2; exit 1; }
[[ "$(pod --version)" == 1.16.2 ]] || { echo 'CocoaPods 1.16.2 is required.' >&2; exit 1; }
[[ "$(ruby -e 'print RUBY_VERSION')" == 3.3.12 ]] || { echo 'Ruby 3.3.12 is required for reproducible podspec checksums.' >&2; exit 1; }
flutter --version --machine | python3 -c 'import json, sys; assert json.load(sys.stdin)["frameworkVersion"] == "3.44.4", "Flutter 3.44.4 is required"'
mkdir -p "$DESTINATION"
flutter pub get --enforce-lockfile
flutter precache --macos
# Check the locked native dependency graph before spending time on compilation.
(cd macos && pod install --deployment)
git ls-files --error-unmatch pubspec.lock macos/Podfile.lock
git diff --exit-code -- pubspec.lock macos/Podfile.lock
python3 tool/macos/check_flutter_framework.py --flutter-root "$FLUTTER_ROOT"
swift test --package-path macos/DesktopSupport --scratch-path "build/macos-desktop/$ARCH"
swift run --package-path macos/DesktopSupport --scratch-path "build/macos-desktop/$ARCH" keqdis-desktop-tests
# Flutter 3.44 produces Universal 2; packaging validates and thins every binary.
flutter build macos --release
git ls-files --error-unmatch pubspec.lock macos/Podfile.lock
git diff --exit-code -- pubspec.lock macos/Podfile.lock
/usr/bin/ditto build/macos/Build/Products/Release/KEQDIS.app "$DESTINATION/KEQDIS.app"
