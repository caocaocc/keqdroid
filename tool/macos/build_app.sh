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
# Flutter 3.44.4 ignores the Xcode deployment target for Dart native assets.
# Compile those assets for 12; never relabel a binary built for a newer system.
python3 - "$FLUTTER_ROOT" <<'PY_NATIVE_ASSETS'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REVISION = 'ad70ec4617166f1c38e5d2bfd388af71fda14f06'
SOURCE = 'packages/flutter_tools/lib/src/isolated/native_assets/macos/native_assets.dart'
ORIGINAL = '197de2e6aabb6ec2098659927d90a862139257ff01037a5e6ec34412a63fb57c'
PATCHED = '129b422ba6569208313d34de25c5e3023a3cd31aef203d94ff381ffdb7cb87be'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(root):
    revision = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                              check=True, text=True, capture_output=True).stdout.strip()
    if revision != REVISION or os.environ.get('FLUTTER_TOOL_ARGS'):
        raise ValueError('Expected the fixed Flutter 3.44.4 SDK without custom tool arguments')
    source = root / SOURCE
    source_hash = digest(source)
    if source_hash not in (ORIGINAL, PATCHED):
        raise ValueError('Flutter native-assets source differs from the audited 3.44.4 file')
    if source_hash == ORIGINAL:
        replacement = source.read_bytes().replace(b'const targetMacOSVersion = 13;',
                                                 b'const targetMacOSVersion = 12;')
        if hashlib.sha256(replacement).hexdigest() != PATCHED:
            raise ValueError('Unexpected native-assets patch result')
        source.write_bytes(replacement)
    tools = root / 'packages/flutter_tools'
    lock = tools / 'pubspec.lock'
    lock_hash = digest(lock)
    cache = root / 'bin/cache'
    snapshot = cache / 'flutter_tools.snapshot'
    stamp = cache / 'flutter_tools.stamp'
    marker = cache / 'keqdroid-macos12-native-assets.json'
    expected = {'sourceSHA256': PATCHED, 'toolsLockSHA256': lock_hash}
    try:
        saved = json.loads(marker.read_text())
        if (saved == dict(expected, snapshotSHA256=digest(snapshot))
                and stamp.read_text().strip() == REVISION + ':'):
            print('Verified cached Flutter native-assets macOS 12 tool snapshot')
            return
    except (OSError, ValueError):
        pass
    # The official bootstrap uses pub upgrade. Preserve its shipped lock here.
    stamp.unlink(missing_ok=True)
    marker.unlink(missing_ok=True)
    dart = root / 'bin/cache/dart-sdk/bin/dart'
    subprocess.run([str(dart), 'pub', 'get', '--enforce-lockfile'], cwd=tools, check=True)
    if digest(lock) != lock_hash:
        raise ValueError('Rebuilding the Flutter tool changed its locked dependencies')
    temporary = snapshot.with_suffix('.keqdroid-building')
    subprocess.run([str(dart), '--verbosity=error', f'--snapshot={temporary}',
                    '--snapshot-kind=app-jit', f'--packages={tools / ".dart_tool/package_config.json"}',
                    '--no-enable-mirrors', str(tools / 'bin/flutter_tools.dart')],
                   check=True, stdout=subprocess.DEVNULL)
    temporary.replace(snapshot)
    os.utime(lock, None)
    stamp.write_text(REVISION + ':\n')
    marker.write_text(json.dumps(dict(expected, snapshotSHA256=digest(snapshot)), sort_keys=True) + '\n')
    print('Rebuilt fixed Flutter 3.44.4 tool with native-assets target macOS 12')

if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve())
PY_NATIVE_ASSETS
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
# Reject incompatible native assets before publishing a reusable app checkpoint.
python3 - build/macos/Build/Products/Release/KEQDIS.app <<'PY_VERIFY_APP'
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, 'tool')
from package_macos import macho_files, inspect_binary

def validate_app(app):
    binaries = macho_files(app)
    if not binaries:
        raise ValueError('The Flutter application contains no Mach-O executables')
    with tempfile.TemporaryDirectory(prefix='keqdroid-verify-app-') as temporary:
        for index, binary in enumerate(binaries):
            arches = subprocess.run(['/usr/bin/lipo', '-archs', str(binary)],
                                    check=True, text=True, capture_output=True).stdout.split()
            if not {'arm64', 'x86_64'}.issubset(arches):
                raise ValueError(f'{binary} is missing a required Universal 2 slice: {arches}')
            for arch, target in (('arm64', 'arm64'), ('x64', 'x86_64')):
                thin = Path(temporary) / f'{index}-{arch}'
                subprocess.run(['/usr/bin/lipo', str(binary), '-thin', target, '-output', str(thin)], check=True)
                try:
                    inspect_binary(thin, arch)
                except ValueError as error:
                    raise ValueError(f'{binary} [{arch}]: {error}') from error
    print(f'Checked both architectures and macOS 12 deployment for {len(binaries)} Mach-O executables')

if __name__ == '__main__':
    validate_app(Path(sys.argv[1]))
PY_VERIFY_APP
/usr/bin/ditto build/macos/Build/Products/Release/KEQDIS.app "$DESTINATION/KEQDIS.app"
