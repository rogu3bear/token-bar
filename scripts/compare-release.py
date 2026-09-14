#!/usr/bin/env python3
"""Compare two pkgutil --expand-full trees after removing app signatures.

Only signature directories and signing-dependent installed size metadata are
excluded. Installer scripts, payload paths/modes, resources, and complete
unsigned executables must agree. Any other difference fails closed.
"""
import hashlib
import os
from pathlib import Path
import stat
import sys
import subprocess
import xml.etree.ElementTree as ET


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.parts[:3] == ('Token Bar.app', 'Contents', '_CodeSignature'):
            continue
        mode = path.lstat().st_mode
        kind = stat.S_IFMT(mode)
        if path.is_symlink():
            value = ('link', os.readlink(path))
        elif path.is_file():
            value = ('file', hashlib.sha256(path.read_bytes()).hexdigest())
        elif path.is_dir():
            value = ('directory', '')
        else:
            raise ValueError(f'Unsupported payload type: {relative}')
        result[str(relative)] = (kind, stat.S_IMODE(mode), value)
    return result


def package_info(path):
    root = ET.parse(path).getroot()
    # Code signatures alter installed size, but not install behavior.
    for node in root.iter():
        node.attrib.pop('installKBytes', None)
    def canonical(node):
        return (node.tag, sorted(node.attrib.items()), (node.text or '').strip(),
                [canonical(child) for child in node])
    return canonical(root)


def compare(left, right):
    allowed = {'Payload', 'Scripts', 'PackageInfo', 'Bom'}
    for root in (left, right):
        if {p.name for p in root.iterdir()} - allowed:
            raise ValueError('Unexpected package component')
        if not (root / 'Payload/Token Bar.app/Contents/MacOS/TokenBar').is_file():
            raise ValueError('Expected Token Bar executable is missing')
        if {p.name for p in (root / 'Payload').iterdir()} != {'Token Bar.app'}:
            raise ValueError('Unexpected top-level payload')
    for part in ('Payload', 'Scripts'):
        a, b = inventory(left / part), inventory(right / part)
        if a != b:
            differing = [name for name in sorted(a.keys() | b.keys()) if a.get(name) != b.get(name)]
            raise ValueError(f'{part} differs: ' + ', '.join(differing))
    def bom(root):
        # Size, checksum and mtime vary with signing/build time. Ownership and modes do not.
        return sorted(line for line in subprocess.check_output(['lsbom', '-p', 'fmug', str(root / 'Bom')], text=True).splitlines()
                      if Path(line.split('\t')[0]).parts[:3] != ('Token Bar.app', 'Contents', '_CodeSignature'))
    if bom(left) != bom(right):
        raise ValueError('Installer bill-of-materials paths, modes or ownership differ')
    if package_info(left / 'PackageInfo') != package_info(right / 'PackageInfo'):
        raise ValueError('Installer metadata differs')


if __name__ == '__main__':
    try:
        compare(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, OSError, ET.ParseError) as error:
        sys.exit(f'FAIL: {error}')
    print('PASS: unsigned payload, resources, modes, installer scripts and metadata match')
