#!/usr/bin/env python3
"""Compare two pkgutil --expand-full trees after removing app signatures.

Only signature directories, signing-dependent installed size metadata and the
__LINKEDIT mapping size that signature removal leaves behind are excluded.
Installer scripts, payload paths/modes, resources, and complete unsigned
executables must agree. Any other difference fails closed.
"""
import hashlib
import os
from pathlib import Path
import stat
import struct
import sys
import subprocess
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bundle_layout import BUNDLE_NAME, payload_executable

PAGE = 0x4000
# A signature is kilobytes; anything beyond this is not signing residue.
SIGNATURE_SLACK = 0x100000


def unsigned_macho(data):
    """Zero __LINKEDIT vmsize in a thin 64-bit Mach-O.

    codesign --remove-signature restores the segment's file size but keeps the
    page-rounded mapping size the removed signature needed, so a Developer ID
    signature and an ad-hoc one can leave different values. The field must stay
    page-aligned and within signature slack of the file size; every other byte,
    including that file size, still compares.
    """
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return data
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    offset, end = 32, 32 + sizeofcmds
    for _ in range(ncmds):
        if offset + 8 > end:
            raise ValueError('Malformed Mach-O load commands')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > end:
            raise ValueError('Malformed Mach-O load commands')
        if command == 0x19 and data[offset + 8:offset + 24].rstrip(b'\0') == b'__LINKEDIT':
            vmsize, _, filesize = struct.unpack_from('<QQQ', data, offset + 32)
            rounded = -(-filesize // PAGE) * PAGE
            if vmsize % PAGE or not rounded <= vmsize <= rounded + SIGNATURE_SLACK:
                raise ValueError('__LINKEDIT mapping size differs beyond signature slack')
            normalized = bytearray(data)
            normalized[offset + 32:offset + 40] = bytes(8)
            return bytes(normalized)
        offset += size
    raise ValueError('Mach-O executable has no __LINKEDIT segment')


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.parts[:3] == (BUNDLE_NAME, 'Contents', '_CodeSignature'):
            continue
        mode = path.lstat().st_mode
        kind = stat.S_IFMT(mode)
        if path.is_symlink():
            value = ('link', os.readlink(path))
        elif path.is_file():
            value = ('file', hashlib.sha256(unsigned_macho(path.read_bytes())).hexdigest())
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
        if not payload_executable(root).is_file():
            raise ValueError('Expected Token Bar executable is missing')
        if {p.name for p in (root / 'Payload').iterdir()} != {BUNDLE_NAME}:
            raise ValueError('Unexpected top-level payload')
    for part in ('Payload', 'Scripts'):
        a, b = inventory(left / part), inventory(right / part)
        if a != b:
            differing = [name for name in sorted(a.keys() | b.keys()) if a.get(name) != b.get(name)]
            raise ValueError(f'{part} differs: ' + ', '.join(differing))
    def bom(root):
        # Size, checksum and mtime vary with signing/build time. Ownership and modes do not.
        return sorted(line for line in subprocess.check_output(['lsbom', '-p', 'fmug', str(root / 'Bom')], text=True).splitlines()
                      if Path(line.split('\t')[0]).parts[:3] != (BUNDLE_NAME, 'Contents', '_CodeSignature'))
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
