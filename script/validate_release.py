#!/usr/bin/env python3
"""Validate packaged products using only an empty, disposable state store."""
import argparse, json, platform, plistlib, subprocess, tarfile, tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
root = args.directory.resolve()
version = (Path(__file__).resolve().parent.parent / 'VERSION').read_text().strip()
app = root / 'Sniff.app'
installer = root / 'Install Sniff.app'

def run(*command, code=0):
    result = subprocess.run(list(map(str, command)), text=True, capture_output=True, timeout=60)
    assert result.returncode == code, f'{command}: {result.stderr} {result.stdout}'
    return result.stdout.strip()

def info(bundle, identifier):
    data = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert data['CFBundleIdentifier'] == identifier
    assert data['CFBundleShortVersionString'] == version
    assert data['LSMinimumSystemVersion'] == '14.0'
    assert set(data['CFBundleLocalizations']) == {'en', 'pt', 'es'}
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', bundle)
    resources = bundle / 'Contents/Resources/Sniff_SniffCore.bundle'
    catalogs = [json.loads(run('/usr/bin/plutil', '-convert', 'json', '-o', '-', resources / f'{c}.lproj/Localizable.strings')) for c in ['en', 'pt', 'es']]
    assert all(set(c) == set(catalogs[0]) for c in catalogs)
    return data

appinfo = info(app, 'app.sniff.mac')
info(installer, 'app.sniff.installer')
info(installer / 'Contents/Resources/Payload/Sniff.app', 'app.sniff.mac')
products = [app / 'Contents/MacOS/Sniff', app / 'Contents/Helpers/sniff', app / 'Contents/Helpers/SniffScheduler', installer / 'Contents/MacOS/SniffInstaller']
architectures = {}
for product in products:
    archs = run('/usr/bin/lipo', '-archs', product).split()
    assert {'arm64', 'x86_64'} == set(archs), f'Expected universal product: {product}: {archs}'
    run('/usr/bin/codesign', '--verify', '--strict', product)
    architectures[product.name] = archs
    data = product.read_bytes()
    assert str(Path.home()).encode() not in data, f'Personal build path embedded in {product}'

checks = []
with tempfile.TemporaryDirectory(prefix='sniff-release-validation-', dir='/private/tmp') as fixture:
    fixture = Path(fixture)
    cli = app / 'Contents/Helpers/sniff'
    assert run(cli, '--version') == version
    for language, heading in [('en', 'USAGE'), ('pt', 'USO'), ('es', 'USO')]:
        helptext = run(cli, '--help', '--language', language)
        assert heading in helptext, f'Localization missing: {language}'
        status = json.loads(run(cli, 'status', '--language', language, '--json', '--state-dir', fixture / language))
        assert status['language'] == language and status['findings'] == 0 and status['cleanupReports'] == 0
    failure = json.loads(run(cli, 'clean', '--json', '--language', 'en', code=2))
    assert failure['exitCode'] == 2
    checks += ['packaged-cli-version', 'packaged-cli-en-pt-es', 'json-usage-error']
    archive = root / f'sniff-{version}-macos-cli.tar.gz'
    unpacked = fixture / 'cli'
    with tarfile.open(archive) as tar:
        # This archive was created by this build, but still reject unsafe paths.
        for member in tar.getmembers():
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts
        tar.extractall(unpacked)
    link = fixture / 'sniff'
    link.symlink_to(unpacked / 'sniff')
    assert run(link, '--version') == version
    assert 'USO' in run(link, '--help', '--language', 'pt')
    checks += ['standalone-cli', 'standalone-cli-symlink-localization']
run('/usr/bin/hdiutil', 'verify', root / f'Sniff-{version}-macos.dmg')
report = {'version': version, 'hostArchitecture': platform.machine(), 'architectures': architectures,
          'signature': appinfo['SniffSigning'], 'notarization': 'not-verified-by-this-script',
          'checks': checks + ['codesign-deep-strict', 'catalog-parity', 'personal-path-exclusion', 'dmg-integrity'],
          'intelRuntimeTested': False, 'realUserCleanupPerformed': False}
(root / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
