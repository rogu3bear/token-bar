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
print('PASS: release comparison rejects changed executable, resource, script, mode, payload and metadata; installed-size normalization is narrow')

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
