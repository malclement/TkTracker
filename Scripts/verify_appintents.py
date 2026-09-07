#!/usr/bin/env python3
"""Fail packaging unless Xcode extracted all public App Intents."""
from pathlib import Path
import json
import sys
root = Path(sys.argv[1]) / 'Contents/Resources/Metadata.appintents'
if not root.is_dir():
    sys.exit('Missing App Intents metadata: use make app APP_BUILDER=xcode with full Xcode.')
files = [p for p in root.rglob('*') if p.suffix in ('.json', '.actionsdata')]
if not files:
    sys.exit('App Intents metadata contains no JSON.')
text = ''
for file in files:
    content = file.read_text()
    json.loads(content)
    text += content
for name in ('TodaySpendIntent', 'RangeSpendIntent', 'BlockRemainingIntent', 'OpenDashboardIntent'):
    if name not in text:
        sys.exit(f'Missing intent in extracted metadata: {name}')
print('All four App Intents are present in valid metadata.')
