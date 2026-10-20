#!/usr/bin/env python3
"""Package already-built SwiftPM products without including local user state."""
import argparse
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--bin-dir', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
parser.add_argument('--identity', default='-')
args = parser.parse_args()
binary = args.bin_dir.resolve()
output = args.output_dir.resolve()
assert any(output == ROOT / name or (ROOT / name) in output.parents for name in ['dist', 'outputs']), 'Use the project dist/ or outputs/ directory.'
output.mkdir(parents=True, exist_ok=True)
version = (ROOT / 'VERSION').read_text().strip()
iconwork = ROOT / 'work' / 'packaging-icons'
iconwork.mkdir(parents=True, exist_ok=True)
png = iconwork / 'Sniff.png'
subprocess.run([str(binary / 'SniffIcon'), str(png)], check=True, stdout=subprocess.DEVNULL)
iconset = iconwork / 'Sniff.iconset'
iconset.mkdir(exist_ok=True)
for size in [16, 32, 128, 256, 512]:
    for multiplier in [1, 2]:
        name = f'icon_{size}x{size}' + ('@2x' if multiplier == 2 else '') + '.png'
        subprocess.run(['/usr/bin/sips', '-z', str(size * multiplier), str(size * multiplier), str(png), '--out', str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
icns = iconwork / 'Sniff.icns'
subprocess.run([sys.executable, str(ROOT / 'script/package_icon.py'), str(iconset), str(icns)], check=True)

def run(*command):
    subprocess.run(list(map(str, command)), check=True)

def sign(path, identifier):
    command = ['/usr/bin/codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--identifier', identifier]
    command += ['--timestamp=none'] if args.identity == '-' else ['--timestamp']
    run(*command, path)

def bundle(path, executable, identifier, display_name):
    if path.exists():
        shutil.rmtree(path)
    contents = path / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    shutil.copy2(binary / executable, contents / 'MacOS' / executable)
    shutil.copy2(icns, contents / 'Resources/Sniff.icns')
    shutil.copytree(binary / 'Sniff_SniffCore.bundle', contents / 'Resources/Sniff_SniffCore.bundle', symlinks=True)
    info = {
        'CFBundleExecutable': executable, 'CFBundleIdentifier': identifier, 'CFBundleName': display_name,
        'CFBundleDisplayName': display_name, 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version, 'CFBundleVersion': '8', 'CFBundleIconFile': 'Sniff',
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'pt', 'es'],
        'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True, 'NSSupportsAutomaticTermination': False,
        'LSApplicationCategoryType': 'public.app-category.utilities', 'SniffPreviewBuild': True,
        'SniffSigning': 'ad-hoc' if args.identity == '-' else 'developer-id',
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    return contents

app = output / 'Sniff.app'
contents = bundle(app, 'Sniff', 'app.sniff.mac', 'Sniff')
(contents / 'Helpers').mkdir()
(contents / 'Library/LaunchAgents').mkdir(parents=True)
shutil.copy2(binary / 'SniffCLI', contents / 'Helpers/sniff')
shutil.copy2(binary / 'SniffScheduler', contents / 'Helpers/SniffScheduler')
job = {
    'Label': 'app.sniff.scheduler', 'BundleProgram': 'Contents/MacOS/Sniff',
    'ProgramArguments': ['Sniff', '--scheduled'], 'StartInterval': 900, 'RunAtLoad': True,
    'ProcessType': 'Background', 'LowPriorityIO': True, 'Nice': 10,
}
(contents / 'Library/LaunchAgents/app.sniff.scheduler.plist').write_bytes(plistlib.dumps(job))
sign(contents / 'Helpers/sniff', 'app.sniff.cli')
sign(contents / 'Helpers/SniffScheduler', 'app.sniff.scheduler.helper')
sign(app, 'app.sniff.mac')
run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
print(app)
