#!/usr/bin/env python3
"""Check that Flutter compiled every shader declared by this repository."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import struct
import zipfile


def declared_shaders(root):
    root = Path(root)
    result = []
    active = False
    for line in (root / 'pubspec.yaml').read_text(encoding='utf-8-sig').splitlines():
        if line == '  shaders:':
            if active or result:
                raise ValueError('Duplicate Flutter shaders declaration')
            active = True
            continue
        if not active or not line.strip() or line.lstrip().startswith('#'):
            continue
        if len(line) - len(line.lstrip()) <= 2:
            active = False
            continue
        match = re.fullmatch(r'    - (shaders/[A-Za-z0-9_./-]+)(?:\s+#.*)?\s*', line)
        if not match:
            raise ValueError('Unsupported Flutter shader declaration: ' + line.strip())
        name = match[1]
        path = PurePosixPath(name)
        if '..' in path.parts or path.as_posix() != name or path.suffix != '.frag' or name in result:
            raise ValueError('Unsafe or duplicate Flutter shader declaration: ' + name)
        source = root / name
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(root.resolve()):
            raise ValueError('Missing or symbolic shader source: ' + name)
        result.append(name)
    return result



def compiled_shader_hash(data, name):
    # The release recipes pin Flutter 3.44.4. Its runtime_stage.fbs declares
    # IPLR and impellerc serializes a FlatBuffer RuntimeStages container.
    # Check that envelope and its root bounds, not GPU/backend semantics.
    error = 'Invalid compiled Flutter 3.44.4 shader: ' + name
    if len(data) < 12 or data[4:8] != b'IPLR':
        raise ValueError(error)
    root = struct.unpack_from('<I', data)[0]
    if root < 8 or root % 4 or root + 4 > len(data):
        raise ValueError(error)
    vtable = root - struct.unpack_from('<i', data, root)[0]
    if vtable < 8 or vtable + 4 > len(data):
        raise ValueError(error)
    vtable_size, object_size = struct.unpack_from('<HH', data, vtable)
    if (vtable_size < 6 or vtable_size % 2 or vtable + vtable_size > len(data)
            or object_size < 8 or root + object_size > len(data)):
        raise ValueError(error)
    return hashlib.sha256(data).hexdigest()


def verify_directory(root, assets):
    assets = Path(assets)
    result = {}
    for name in declared_shaders(root):
        path = assets / name
        if (path.is_symlink() or not path.is_file() or not path.stat().st_size
                or not path.resolve().is_relative_to(assets.resolve())):
            raise ValueError('Missing compiled Flutter shader: ' + name)
        result[name] = compiled_shader_hash(path.read_bytes(), name)
    return result


def verify_apk(root, apk):
    result = {}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        for name in declared_shaders(root):
            entry = 'assets/flutter_assets/' + name
            if names.count(entry) != 1 or not archive.getinfo(entry).file_size:
                raise ValueError('Missing or duplicate compiled Flutter shader: ' + name)
            result[name] = compiled_shader_hash(archive.read(entry), name)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--assets', type=Path, required=True)
    args = parser.parse_args()
    print(f'Checked {len(verify_directory(args.root, args.assets))} compiled Flutter shaders')
