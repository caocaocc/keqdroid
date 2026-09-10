#!/usr/bin/env python3
"""Build and inspect an ad-hoc signed, architecture-specific DMG. Never installs it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from macos.build_cores import macho_info, validate_core_set

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = Path('Library/Application Support/io.github.caocaocc.keqdroid.incoming')
CORES = ('keqrnel', 'mihomo', 'wireproxy')
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, text=True, **kwargs)


def sha(path):
    with Path(path).open('rb') as source:
        digest = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def macho_files(directory):
    files = []
    for path in sorted(Path(directory).rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) in MAGIC:
                files.append(path)
    return files


def inspect_binary(path, arch):
    # Share the core builder's binary parser: otool text can hide a different
    # Apple platform or an incompatible patch-level deployment requirement.
    return macho_info(Path(path), arch)


def validate_provenance(cores, provenance, arch):
    expected = validate_core_set(cores, arch)
    if provenance != expected:
        raise ValueError('Aggregate core provenance differs from the verified component records')


def resolve_helper(prebuilt, arch):
    if prebuilt is None:
        target = 'arm64' if arch == 'arm64' else 'x86_64'
        command = ['swift', 'build', '--package-path', ROOT / 'macos/NetworkService',
                   '-c', 'release', '--arch', target]
        run(*command, '--product', 'keqdis-network-service')
        directory = run(*command, '--show-bin-path', capture_output=True).stdout.strip()
        prebuilt = Path(directory) / 'keqdis-network-service'
    if prebuilt.is_symlink() or not prebuilt.is_file():
        raise ValueError(f'Missing regular helper executable: {prebuilt}')
    inspect_binary(prebuilt, arch)
    return prebuilt


def normalize_modes(directory):
    for path in [directory, *directory.rglob('*')]:
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)


def component_properties(payload, destination):
    run('/usr/bin/pkgbuild', '--analyze', '--root', payload, destination)
    with destination.open('rb') as source:
        components = plistlib.load(source)

    def configure(items):
        for item in items:
            # Installer must place every bundle in .incoming. Its normal bundle
            # search/skip behavior could overwrite the running app before our
            # rollback transaction or leave the staged payload incomplete.
            item['BundleIsRelocatable'] = False
            item['BundleIsVersionChecked'] = False
            item['BundleHasStrictIdentifier'] = True
            item['BundleOverwriteAction'] = 'upgrade'
            configure(item.get('ChildBundles', []))

    configure(components)
    with destination.open('wb') as output:
        plistlib.dump(components, output)


def sign(path, entitlements=None):
    command = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime']
    if entitlements:
        command += ['--entitlements', str(entitlements)]
    run(*command, path)


def seal_app(app, arch):
    # Thin vendored universal frameworks before sealing; no post-sign modifications.
    expected = 'arm64' if arch == 'arm64' else 'x86_64'
    for binary in macho_files(app):
        arches = run('/usr/bin/lipo', '-archs', binary, capture_output=True).stdout.split()
        if arches != [expected]:
            if expected not in arches:
                raise ValueError(f'{binary}: missing {expected} slice')
            thin = binary.with_name(binary.name + '.thin')
            run('/usr/bin/lipo', binary, '-thin', expected, '-output', thin)
            thin.chmod(binary.stat().st_mode)
            thin.replace(binary)
        inspect_binary(binary, arch)
        sign(binary)
    bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink()
               and p.suffix in ('.framework', '.app', '.xpc', '.appex', '.bundle')]
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        # Resource-only plugin bundles have no executable to sign.
        if macho_files(bundle):
            sign(bundle)
    sign(app, ROOT / 'macos/Runner/Release.entitlements')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    details = run('/usr/bin/codesign', '-d', '--verbose=4', app, capture_output=True).stderr
    fingerprints = re.findall(r'^CDHash=([a-f0-9]{40})$', details, re.MULTILINE)
    if len(fingerprints) != 1:
        raise ValueError('Expected a single signed application fingerprint')
    return f'cdhash H"{fingerprints[0]}"'


def distribution_xml(package_name, architecture, uninstall=False):
    # productbuild enforces OS/architecture before any installer scripts run.
    title = 'Uninstall KEQDIS' if uninstall else 'Install KEQDIS'
    identifier = 'io.github.caocaocc.keqdroid.uninstaller' if uninstall else 'io.github.caocaocc.keqdroid.installer'
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
 <title>{title}</title>
 <options customize="never" require-scripts="false" hostArchitectures="{architecture}"/>
 <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
 <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
 <choices-outline><line choice="default"/></choices-outline>
 <choice id="default" visible="false"><pkg-ref id="{identifier}"/></choice>
 <pkg-ref id="{identifier}" auth="Root">{package_name}</pkg-ref>
</installer-gui-script>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['arm64', 'x64'], required=True)
    parser.add_argument('--app', type=Path, help='Use an already built Flutter app')
    parser.add_argument('--cores', type=Path, help='Directory with cores and provenance.json')
    parser.add_argument('--helper', type=Path, help='Use an already built network service executable')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/macos-release')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Packaging requires macOS and full Xcode')
    run('/usr/bin/xcodebuild', '-version')
    version = re.search(r'^version:\s*([^+\s]+)', (ROOT / 'pubspec.yaml').read_text(), re.MULTILINE).group(1)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Invalid package version')
    target = 'arm64' if args.arch == 'arm64' else 'x86_64'
    args.output.mkdir(parents=True, exist_ok=True)
    if args.app is None:
        # Flutter 3.44 builds a universal release; seal_app thins every Mach-O.
        run('flutter', 'build', 'macos', '--release', cwd=ROOT)
        args.app = ROOT / 'build/macos/Build/Products/Release/KEQDIS.app'
    cores = args.cores or ROOT / 'build/macos-cores' / args.arch
    for core in CORES:
        if not (cores / core).is_file():
            raise ValueError(f'Missing pinned core: {cores / core}; run tool/build_macos_cores.sh first')
    provenance = json.loads((cores / 'provenance.json').read_text())
    validate_provenance(cores, provenance, args.arch)
    prebuilt_helper = resolve_helper(args.helper, args.arch)
    with tempfile.TemporaryDirectory(prefix='keqdis-package-', dir=args.output) as temporary:
        work = Path(temporary)
        payload = work / 'payload'
        stage = payload / SUPPORT
        runtime = stage / 'runtime'
        app = stage / 'KEQDIS.app'
        (runtime / 'bin').mkdir(parents=True)
        run('/usr/bin/ditto', args.app, app)
        bundle_cores = app / 'Contents/Resources/cores'
        bundle_cores.mkdir(parents=True, exist_ok=True)
        bundle_geo = app / 'Contents/Resources/geo'
        bundle_geo.mkdir(parents=True, exist_ok=True)
        for core in CORES:
            shutil.copy2(cores / core, bundle_cores / core)
        for geo in ('geoip.dat', 'geosite.dat'):
            shutil.copy2(ROOT / 'assets/bin/linux' / geo, bundle_geo / geo)
        # Other platforms' executables are asset-bundled by Flutter but cannot run here.
        for other in ('linux', 'windows'):
            unused = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin' / other
            if unused.is_dir():
                shutil.rmtree(unused)
        normalize_modes(app)
        fingerprint = seal_app(app, args.arch)
        for core in CORES:
            shutil.copy2(bundle_cores / core, runtime / 'bin' / core)
        helper = runtime / 'bin/keqdis-network-service'
        shutil.copy2(prebuilt_helper, helper)
        helper.chmod(0o755)
        inspect_binary(helper, args.arch)
        sign(helper)
        run('/usr/bin/codesign', '--verify', '--strict', helper)
        run(helper, '--self-check')
        shutil.copytree(bundle_geo, runtime / 'geo')
        shutil.copy2(ROOT / 'tool/macos/installer/network-service.plist', runtime / 'network-service.plist')
        (runtime / 'client-requirement.txt').write_text(fingerprint + '\n')
        hashes = {core: {'sha256': sha(runtime / 'bin' / core)} for core in CORES}
        (runtime / 'core-manifest.json').write_text(json.dumps(hashes, indent=2) + '\n')
        (runtime / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        # The app and executable signatures are complete. Normalize only the
        # remaining payload metadata, never mutate sealed code afterward.
        for path in [payload, payload / 'Library', payload / 'Library/Application Support', stage, runtime, runtime / 'bin']:
            path.chmod(0o755)
        normalize_modes(runtime / 'geo')
        for path in runtime.iterdir():
            if path.is_file():
                path.chmod(0o644)
        scripts = work / 'scripts'
        scripts.mkdir()
        for name in ('preinstall', 'postinstall'):
            shutil.copy2(ROOT / 'tool/macos/installer' / name, scripts / name)
            (scripts / name).chmod(0o755)
        component = work / 'install-component.pkg'
        components = work / 'components.plist'
        component_properties(payload, components)
        run('/usr/bin/pkgbuild', '--root', payload, '--install-location', '/', '--ownership', 'recommended',
            '--identifier', 'io.github.caocaocc.keqdroid.installer', '--version', version.split('-')[0],
            '--component-plist', components, '--scripts', scripts, component)
        media = work / 'media'
        media.mkdir()
        for uninstall in (False, True):
            name = 'uninstall-component.pkg' if uninstall else component.name
            if uninstall:
                uninstall_scripts = work / 'uninstall-scripts'
                uninstall_scripts.mkdir()
                shutil.copy2(ROOT / 'tool/macos/installer/uninstall', uninstall_scripts / 'preinstall')
                (uninstall_scripts / 'preinstall').chmod(0o755)
                run('/usr/bin/pkgbuild', '--nopayload', '--scripts', uninstall_scripts, '--identifier',
                    'io.github.caocaocc.keqdroid.uninstaller', '--version', version.split('-')[0], work / name)
            distribution = work / ('uninstall.xml' if uninstall else 'install.xml')
            distribution.write_text(distribution_xml(name, target, uninstall))
            run('/usr/bin/productbuild', '--distribution', distribution, '--package-path', work,
                media / ('Uninstall KEQDIS.pkg' if uninstall else 'Install KEQDIS.pkg'))
        shutil.copy2(ROOT / 'tool/macos/installer/README.txt', media / 'README.txt')
        revision = run('git', 'rev-parse', 'HEAD', cwd=ROOT, capture_output=True).stdout.strip()
        report = {'version': version, 'architecture': args.arch, 'signature': 'ad-hoc',
                  'sourceCommit': revision, 'githubRunId': os.environ.get('GITHUB_RUN_ID'),
                  'githubRunAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                  'coreComponentInputs': provenance['componentInputs'],
                  'installerSignature': 'unsigned', 'notarized': False,
                  'podfileLockSHA256': sha(ROOT / 'macos/Podfile.lock'),
                  'clientRequirement': fingerprint, 'coresAfterSigning': hashes,
                  'files': {str(p.relative_to(stage)): inspect_binary(p, args.arch) for p in macho_files(stage)}}
        report_name = f'keqdroid-{version}-macos-{args.arch}-verification.json'
        (args.output / report_name).write_text(json.dumps(report, indent=2) + '\n')
        dmg = args.output / f'keqdroid-{version}-macos-{args.arch}.dmg'
        run('/usr/bin/hdiutil', 'create', '-ov', '-format', 'UDZO', '-fs', 'HFS+', '-volname', f'KEQDIS {version}',
            '-srcfolder', media, dmg)
        run('/usr/bin/hdiutil', 'verify', dmg)
        dmg.with_suffix('.dmg.sha256').write_text(f'{sha(dmg)}  {dmg.name}\n')
        print(f'Created {dmg}. Runtime installation and macOS 12 acceptance are still required.')


if __name__ == '__main__':
    main()
