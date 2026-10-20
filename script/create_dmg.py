#!/usr/bin/env python3
"""Create the standard Finder drag-and-drop disk image."""
import argparse
from pathlib import Path
import dmgbuild

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
app, output = args.app.resolve(), args.output.resolve()
assert app.name == 'Sniff.app' and (app / 'Contents/Info.plist').is_file()
output.parent.mkdir(parents=True, exist_ok=True)
dmgbuild.build_dmg(str(output), 'Sniff', settings={
    'files': [str(app)],
    'symlinks': {'Applications': '/Applications'},
    'background': 'builtin-arrow',
    'format': 'UDZO',
    'filesystem': 'HFS+',
    'window_rect': ((200, 160), (640, 280)),
    'default_view': 'icon-view',
    'icon_locations': {'Sniff.app': (140, 120), 'Applications': (500, 120)},
    'icon_size': 128,
    'text_size': 14,
    'show_status_bar': False,
    'show_tab_view': False,
    'show_toolbar': False,
    'show_pathbar': False,
    'show_sidebar': False,
    'arrange_by': None,
})
print(output)
