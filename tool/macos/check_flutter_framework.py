#!/usr/bin/env python3
"""Load the real ad-hoc Flutter framework under Hardened Runtime, without a GUI."""
import argparse
import importlib.util
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-root', required=True, type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(ROOT / 'tool'))
    spec = importlib.util.spec_from_file_location('package_macos', ROOT / 'tool/package_macos.py')
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x64'
    target = 'arm64' if architecture == 'arm64' else 'x86_64'
    frameworks = args.flutter_root / 'bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64'
    if not (frameworks / 'FlutterMacOS.framework').is_dir():
        parser.error('Run flutter precache --macos with Flutter 3.44.4 first')
    with tempfile.TemporaryDirectory(prefix='keqdis-flutter-runtime-') as temporary:
        work = Path(temporary)
        app = work / 'FrameworkCheck.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Frameworks').mkdir()
        source = work / 'main.swift'
        source.write_text('''import Foundation
import FlutterMacOS
guard FlutterDartProject.defaultBundleIdentifier() == "io.flutter.flutter.app" else { exit(1) }
print("FlutterMacOS loaded under ad-hoc Hardened Runtime")
''')
        executable = app / 'Contents/MacOS/framework-check'
        package.run('swiftc', '-O', '-target', target + '-apple-macosx12.0', '-module-cache-path', work / 'module-cache',
                    '-F', frameworks, '-framework', 'FlutterMacOS', '-Xlinker', '-rpath', '-Xlinker',
                    '@executable_path/../Frameworks', source, '-o', executable)
        package.run('/usr/bin/ditto', frameworks / 'FlutterMacOS.framework', app / 'Contents/Frameworks/FlutterMacOS.framework')
        with (app / 'Contents/Info.plist').open('wb') as output:
            plistlib.dump({'CFBundleExecutable': executable.name, 'CFBundleIdentifier': 'test.keqdis.flutter-runtime',
                          'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '12.0'}, output)
        package.normalize_modes(app)
        package.seal_app(app, architecture)
        details = package.run('/usr/bin/codesign', '-d', '--verbose=4', app, capture_output=True).stderr
        if not re.search(r'flags=0x[0-9a-f]+\([^)]*\bruntime\b', details):
            raise RuntimeError('The fixture must use Hardened Runtime')
        result = subprocess.run([str(executable)], check=True, text=True, capture_output=True)
        if result.stdout.strip() != 'FlutterMacOS loaded under ad-hoc Hardened Runtime':
            raise RuntimeError('Flutter framework loading did not complete')
        print(result.stdout.strip())
        print('This verifies framework loading only, not Runner, plugins, Gatekeeper or macOS 12 runtime.')


if __name__ == '__main__':
    main()
