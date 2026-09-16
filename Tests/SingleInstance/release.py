#!/usr/bin/env python3
"""Synthetic release-content comparator checks; no installer is executed."""
import importlib.util
from pathlib import Path
import os
import sys
sys.dont_write_bytecode = True
import shutil
import subprocess
import tempfile

owner = Path(__file__).resolve().parents[2] / 'scripts/compare-release.py'
spec = importlib.util.spec_from_file_location('release_comparison', owner)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix='tokenbar-release-test-') as temporary:
    root = Path(temporary)
    left, right = root / 'left', root / 'right'
    app = left / 'Payload/Token Bar.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'MacOS/TokenBar').write_bytes(b'synthetic unsigned executable')
    (app / 'Resources/icon').write_bytes(b'icon')
    (left / 'Scripts').mkdir()
    (left / 'Scripts/preinstall').write_text('# synthetic installer fixture\n')
    (left / 'PackageInfo').write_text('<pkg-info identifier="local.star.CodexTokenBar"><payload installKBytes="1"/></pkg-info>')
    subprocess.run(['mkbom', str(left / 'Payload'), str(left / 'Bom')], check=True)
    shutil.copytree(left, right)
    module.compare(left, right)
    def rejected(change, restore):
        change()
        try:
            module.compare(left, right)
        except ValueError:
            pass
        else:
            raise AssertionError('Changed installer content was accepted')
        restore()
    for relative in ['Payload/Token Bar.app/Contents/MacOS/TokenBar', 'Payload/Token Bar.app/Contents/Resources/icon', 'Scripts/preinstall']:
        path = right / relative
        original = path.read_bytes()
        rejected(lambda: path.write_bytes(b'different synthetic content'), lambda: path.write_bytes(original))
    binary = right / 'Payload/Token Bar.app/Contents/MacOS/TokenBar'
    original_mode = binary.stat().st_mode & 0o777
    rejected(lambda: binary.chmod(0o777), lambda: binary.chmod(original_mode))
    extra = right / 'Payload/extra'
    rejected(lambda: extra.write_bytes(b'extra'), lambda: extra.unlink())
    metadata = right / 'PackageInfo'
    rejected(lambda: metadata.write_text('<pkg-info identifier="different"/>'),
             lambda: shutil.copy2(left / 'PackageInfo', metadata))
    metadata.write_text('<pkg-info identifier="local.star.CodexTokenBar"><payload installKBytes="2"/></pkg-info>')
    module.compare(left, right)
    # Signature removal can leave a different page-rounded __LINKEDIT mapping size; nothing else may differ.
    import struct
    def macho(vmsize, filesize=0x5000, code=b'code'):
        header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 72, 0, 0)
        segment = struct.pack('<II16sQQQQiiII', 0x19, 72, b'__LINKEDIT', 0x100000000, vmsize, 0x4000, filesize, 1, 1, 0, 0)
        return header + segment + code
    for side in (left, right):
        (side / 'Payload/Token Bar.app/Contents/MacOS/TokenBar').write_bytes(macho(0x8000))
    module.compare(left, right)
    binary.write_bytes(macho(0xc000))
    module.compare(left, right)
    for changed in (macho(0x8000 + 0x104000), macho(0x9000), macho(0x4000), macho(0x8000, filesize=0x5001), macho(0x8000, code=b'edit')):
        rejected(lambda: binary.write_bytes(changed), lambda: binary.write_bytes(macho(0x8000)))
    truncated = macho(0x8000)[:40]
    rejected(lambda: binary.write_bytes(truncated), lambda: binary.write_bytes(macho(0x8000)))
print('PASS: release comparison rejects changed executable, resource, script, mode, payload and metadata; installed-size and signature-residue normalization is narrow')

# Exercise the real shell entry points without compiling or contacting Apple.
with tempfile.TemporaryDirectory(prefix='tokenbar-output-test-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    (root / 'site').mkdir()
    (root / 'VERSION').write_text('9.8.7\n')
    for name in ('package.sh', 'release.sh'):
        shutil.copy2(owner.parent / name, root / 'scripts' / name)
    marker = root / 'producer-ran'
    for name in ('build.sh', 'test.sh'):
        script = root / 'scripts' / name
        script.write_text('#!/bin/bash\ntouch producer-ran\nexit 73\n')
        script.chmod(0o700)
    env = dict(os.environ, APP_SIGNING_IDENTITY='synthetic',
               INSTALLER_SIGNING_IDENTITY='synthetic', NOTARY_PROFILE='synthetic')
    env.pop('TOKENBAR_DIST_DIR', None)
    for name, outputs in (
        ('package.sh', ['TokenBar-9.8.7-arm64.pkg', 'TokenBar-9.8.7-arm64.pkg.sha256']),
        ('release.sh', ['TokenBar-9.8.7-arm64.pkg', 'TokenBar-9.8.7-arm64.pkg.sha256', 'notarization-9.8.7.json']),
    ):
        for custom in (False, True):
            destination = root / ('custom output' if custom else 'dist')
            destination.mkdir(exist_ok=True)
            run_env = dict(env)
            if custom:
                run_env['TOKENBAR_DIST_DIR'] = str(destination)
            for output in outputs:
                path = destination / output
                path.write_bytes(b'older artifact')
                result = subprocess.run([str(root / 'scripts' / name)], env=run_env, capture_output=True)
                assert result.returncode == 1 and not marker.exists(), result.stderr
                assert path.read_bytes() == b'older artifact'
                path.unlink()
                path.symlink_to(destination / 'absent')
                result = subprocess.run([str(root / 'scripts' / name)], env=run_env, capture_output=True)
                assert result.returncode == 1 and path.is_symlink() and not marker.exists()
                path.unlink()
            result = subprocess.run([str(root / 'scripts' / name)], env=run_env, capture_output=True)
            assert result.returncode == 73 and marker.exists(), result.stderr
            marker.unlink()
print('PASS: package/release preserve existing artifacts and dangling links before producers; fresh default/custom destinations proceed')

# The checksum sidecar is uploaded beside the installer, so it must name only the basename.
with tempfile.TemporaryDirectory(prefix='tokenbar-sidecar-test-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    (root / 'VERSION').write_text('9.8.7\n')
    shutil.copy2(owner.parent / 'package.sh', root / 'scripts/package.sh')
    shutil.copytree(owner.parent / 'pkg', root / 'scripts/pkg')
    app = root / 'build/Token Bar.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'MacOS/TokenBar').write_bytes(b'#!/bin/sh\nexit 0\n')
    (app / 'MacOS/TokenBar').chmod(0o755)
    (app / 'Info.plist').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        '<key>CFBundleIdentifier</key><string>local.star.CodexTokenBar</string>'
        '<key>CFBundleShortVersionString</key><string>9.8.7</string>'
        '<key>CFBundleVersion</key><string>39807</string>'
        '<key>CFBundleExecutable</key><string>TokenBar</string></dict></plist>\n')
    build = root / 'scripts/build.sh'
    build.write_text('#!/bin/bash\nexit 0\n')
    build.chmod(0o700)
    dist = root / 'dist out'
    env = {k: v for k, v in os.environ.items() if k != 'INSTALLER_SIGNING_IDENTITY'}
    env['TOKENBAR_DIST_DIR'] = str(dist)
    result = subprocess.run([str(root / 'scripts/package.sh')], env=env, capture_output=True)
    assert result.returncode == 0, result.stderr
    sidecar = (dist / 'TokenBar-9.8.7-arm64.pkg.sha256').read_text()
    assert '/' not in sidecar and sidecar.split()[1] == 'TokenBar-9.8.7-arm64.pkg', sidecar
    check = subprocess.run(['shasum', '-a', '256', '-c', 'TokenBar-9.8.7-arm64.pkg.sha256'], cwd=dist, capture_output=True)
    assert check.returncode == 0, check.stderr
print('PASS: package checksum sidecar names only the installer basename and verifies from its own directory')

# Invalid public versions must fail before a build epoch could make them look usable.
with tempfile.TemporaryDirectory(prefix='tokenbar-version-test-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    for name in ('build.sh', 'sources.sh'):
        shutil.copy2(owner.parent / name, root / 'scripts' / name)
    for version in ('', '0.1', 'bad', '0.100.0', '0.1.100', '0.01.0', '-1.1.0'):
        (root / 'VERSION').write_text(version + '\n')
        result = subprocess.run(['bash', str(root / 'scripts/build.sh')], capture_output=True)
        assert result.returncode == 1 and b'VERSION must be' in result.stderr
        assert not (root / 'build').exists(), 'Invalid version must fail before build output'
print('PASS: public build epoch rejects malformed and colliding version components before building')
