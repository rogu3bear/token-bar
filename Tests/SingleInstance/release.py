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

# The checksum sidecar is published beside the installer, so scripts/checksum.sh owns
# one rule: name the basename, never a build path. Both producers call it.
MINIMAL = {'PATH': '/usr/bin:/bin:/usr/sbin', 'LC_ALL': 'C'}
checksum = owner.parent / 'checksum.sh'
with tempfile.TemporaryDirectory(prefix='tokenbar-sidecar-test-') as temporary:
    root = Path(temporary)
    out = root / 'dist out'
    out.mkdir()
    package = out / 'TokenBar-9.8.7-arm64.pkg'
    package.write_bytes(b'synthetic installer')
    sidecar = Path(str(package) + '.sha256')

    def written(cwd, argument, env=None):
        result = subprocess.run([str(checksum), argument], cwd=cwd,
                                env=dict(MINIMAL, TMPDIR=temporary, **(env or {})), capture_output=True)
        assert result.returncode == 0, result.stderr
        return sidecar.read_text()

    for cwd, argument, env in [
        (root, str(package), None),
        # A relative output directory must not be redirected by the caller's CDPATH.
        (root, 'dist out/TokenBar-9.8.7-arm64.pkg', {'CDPATH': str(root / 'decoy')}),
    ]:
        (root / 'decoy/dist out').mkdir(parents=True, exist_ok=True)
        text = written(cwd, argument, env)
        assert '/' not in text, text
        assert text.split()[1] == package.name, text
        check = subprocess.run(['shasum', '-a', '256', '-c', sidecar.name], cwd=out, capture_output=True)
        assert check.returncode == 0, check.stderr
        assert not (root / 'decoy/dist out' / sidecar.name).exists(), 'CDPATH redirected the sidecar'
        sidecar.unlink()

    # Stapling changes the package, so a caller re-hashes; the sidecar must follow.
    written(root, str(package))
    stale = sidecar.read_text()
    package.write_bytes(b'synthetic installer, stapled')
    assert subprocess.run(['shasum', '-a', '256', '-c', sidecar.name], cwd=out, capture_output=True).returncode == 1
    written(root, str(package))
    assert sidecar.read_text() != stale
    assert subprocess.run(['shasum', '-a', '256', '-c', sidecar.name], cwd=out, capture_output=True).returncode == 0

    # A failure must not leave an empty sidecar behind, and a missing package is an argument error.
    sidecar.unlink()
    for arguments, existing in ((['nowhere.pkg'], False), ([], False)):
        result = subprocess.run([str(checksum)] + arguments, cwd=root,
                                env=dict(MINIMAL, TMPDIR=temporary), capture_output=True)
        assert result.returncode == 2, result.stdout + result.stderr
    assert not sidecar.exists()
    result = subprocess.run([str(checksum), str(package)], cwd=root,
                            env={'PATH': str(root / 'empty'), 'TMPDIR': temporary}, capture_output=True)
    assert result.returncode != 0 and not sidecar.exists(), 'a failed hash must leave no sidecar'
print('PASS: checksum.sh writes a basename-only sidecar that verifies in place, survives CDPATH, re-hashes changed bytes and leaves nothing behind on failure')

# package.sh must reach that owner, so the shipping path is the tested one.
with tempfile.TemporaryDirectory(prefix='tokenbar-package-sidecar-test-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    (root / 'VERSION').write_text('9.8.7\n')
    shutil.copy2(owner.parent / 'package.sh', root / 'scripts/package.sh')
    shutil.copy2(checksum, root / 'scripts/checksum.sh')
    shutil.copytree(owner.parent / 'pkg', root / 'scripts/pkg')
    app = root / 'build/Token Bar.app/Contents'
    app.mkdir(parents=True)
    (app / 'Info.plist').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        '<key>CFBundleIdentifier</key><string>local.star.CodexTokenBar</string>'
        '<key>CFBundleShortVersionString</key><string>9.8.7</string><key>CFBundleVersion</key><string>39807</string></dict></plist>\n')
    build = root / 'scripts/build.sh'
    build.write_text('#!/bin/bash\nexit 0\n')
    build.chmod(0o700)
    dist = root / 'dist out'
    result = subprocess.run([str(root / 'scripts/package.sh')], cwd=root, capture_output=True,
                            env=dict(MINIMAL, TMPDIR=temporary, TOKENBAR_DIST_DIR=str(dist)))
    assert result.returncode == 0, result.stderr
    text = (dist / 'TokenBar-9.8.7-arm64.pkg.sha256').read_text()
    assert '/' not in text and text.split()[1] == 'TokenBar-9.8.7-arm64.pkg', text
    assert subprocess.run(['shasum', '-a', '256', '-c', 'TokenBar-9.8.7-arm64.pkg.sha256'],
                          cwd=dist, capture_output=True).returncode == 0
    # Installer compares short versions first, so bundle version checking must stay off
    # (a legacy 2.x build would otherwise silently survive); preinstall reads the build instead.
    import xml.etree.ElementTree as ET
    expanded = root / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(dist / 'TokenBar-9.8.7-arm64.pkg'), str(expanded)], check=True, capture_output=True)
    info = ET.parse(expanded / 'PackageInfo').getroot()
    assert len(list(info.find('bundle-version'))) == 0, 'bundle version checking must be off'
    assert [b.get('id') for b in info.find('upgrade-bundle')] == ['local.star.CodexTokenBar']
    assert [b.get('id') for b in info.find('strict-identifier')] == ['local.star.CodexTokenBar']
    assert (expanded / 'Scripts/build').read_text() == '39807\n', 'preinstall receives the packaged bundle build'
    assert (expanded / 'Scripts/preinstall').read_bytes() == (owner.parent / 'pkg/preinstall').read_bytes()
print('PASS: package.sh writes its sidecar through checksum.sh')
print('PASS: packages disable Installer short-version checking and carry the exact bundle build for preinstall')

# verify-release.sh is the pre-publication gate, so it must reject a sidecar a downloader cannot use.
verifier = owner.parent / 'verify-release.sh'
with tempfile.TemporaryDirectory(prefix='tokenbar-gate-test-') as temporary:
    root = Path(temporary)
    package = root / 'TokenBar-9.8.7-arm64.pkg'
    package.write_bytes(b'synthetic installer')
    sidecar = Path(str(package) + '.sha256')
    digest = subprocess.run(['shasum', '-a', '256', package.name], cwd=root,
                            capture_output=True, text=True).stdout.split()[0]
    def gate():
        return subprocess.run([str(verifier), 'HEAD', str(package)], capture_output=True, text=True)
    for text, expected in [
        (f'{digest}  {package}\n', 'not the installer basename'),
        (f'{digest}  {package.name}\n{digest}  other\n', 'not a single line'),
        (f'{"0" * 64}  {package.name}\n', 'does not match the package bytes'),
    ]:
        sidecar.write_text(text)
        result = gate()
        assert result.returncode == 1 and expected in result.stderr, (expected, result.stderr)
        assert 'PASS: checksum sidecar' not in result.stdout
    # A correct sidecar passes this gate; the synthetic package then fails the signature gate.
    sidecar.write_text(f'{digest}  {package.name}\n')
    result = gate()
    assert 'PASS: checksum sidecar' in result.stdout and 'Developer ID installer certificate' in result.stderr
    # Absence is reported, not silently accepted.
    sidecar.unlink()
    result = gate()
    assert 'NOTE: no checksum sidecar' in result.stdout
print('PASS: verify-release.sh rejects a path-bearing, malformed or stale sidecar before the signature gate and reports an absent one')

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

# build.sh writes Info.plist after compile. Local CI must still reach that plist
# without linking the app: stub the compiler and codesign, keep the real script.
def prepare_bundle_tree(root, version='9.8.7'):
    (root / 'scripts').mkdir()
    (root / 'Sources').mkdir()
    (root / 'Assets').mkdir()
    (root / 'bin').mkdir()
    (root / 'VERSION').write_text(version + '\n')
    (root / 'Sources/Stub.swift').write_text('enum Stub {}\n')
    (root / 'Assets/TokenBar.icns').write_bytes(b'icns')
    relay = root / 'Assets/claude-statusline-relay.sh'
    relay.write_text('#!/bin/sh\n')
    relay.chmod(0o755)
    xcrun = root / 'bin/xcrun'
    xcrun.write_text('''#!/bin/bash
if [ "$1" = swiftc ] && [ "$2" = --version ]; then
  echo 'Apple Swift version 6.0'
  exit 0
fi
if [ "$1" = swiftc ]; then
  out=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-o" ]; then out="$arg"; fi
    prev="$arg"
  done
  mkdir -p "$(dirname "$out")"
  printf '#!/bin/sh\\n' > "$out"
  chmod 755 "$out"
  exit 0
fi
exit 1
''')
    xcrun.chmod(0o700)
    codesign = root / 'bin/codesign'
    codesign.write_text('#!/bin/bash\nexit 0\n')
    codesign.chmod(0o700)
    shutil.copy2(owner.parent / 'build.sh', root / 'scripts/build.sh')
    shutil.copy2(owner.parent / 'sources.sh', root / 'scripts/sources.sh')
    return {'PATH': str(root / 'bin') + ':/usr/bin:/bin', 'TMPDIR': str(root), 'LC_ALL': 'C'}

def run_build(root, env):
    return subprocess.run(['bash', str(root / 'scripts/build.sh')], cwd=root, env=env, capture_output=True)

with tempfile.TemporaryDirectory(prefix='tokenbar-appl-missing-test-') as temporary:
    root = Path(temporary)
    env = prepare_bundle_tree(root)
    script = root / 'scripts/build.sh'
    script.write_text(script.read_text().replace(
        '<key>CFBundlePackageType</key><string>APPL</string>\n', ''))
    result = run_build(root, env)
    assert result.returncode == 1 and b'CFBundlePackageType must be APPL' in result.stderr, result.stderr
    assert not (root / 'build/Token Bar.app').exists(), 'A bundle without APPL must not be published'

with tempfile.TemporaryDirectory(prefix='tokenbar-appl-test-') as temporary:
    root = Path(temporary)
    env = prepare_bundle_tree(root)
    result = run_build(root, env)
    assert result.returncode == 0, result.stderr
    plist = root / 'build/Token Bar.app/Contents/Info.plist'
    def plist_value(key):
        return subprocess.check_output(
            ['/usr/libexec/PlistBuddy', '-c', 'Print :' + key, str(plist)], text=True).strip()
    assert plist_value('CFBundlePackageType') == 'APPL'
    assert plist_value('CFBundleShortVersionString') == '9.8.7'
    assert plist_value('CFBundleVersion') == '120807'
print('PASS: shipping Info.plist is APPL and a missing package type fails closed before signing')
