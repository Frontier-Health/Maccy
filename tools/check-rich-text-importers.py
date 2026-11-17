#!/usr/bin/env python3
"""Fail if app code renders copied rich text with WebKit or imports RTF outside the bounded paths.

Clipboard content is untrusted (A7). HTML is only ever scanned by
ClipboardHTMLText; nothing may hand it to the WebKit-backed importer, which can
load remote resources. RTF goes to AppKit's reader only through
RichTextImport (bounded) and IgnoreRules (bounded by the ignore-rule limits).
Comment lines are ignored, so code can name what it avoids.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = [
    (r'NSAttributedString\s*\(\s*html\s*:', 'WebKit HTML importer'),
    (r'NSAttributedString\s*\(\s*(data|url|contentsOf|path)\s*:', 'document importer that can select HTML'),
    (r'\.read\s*\(\s*from\s*:', 'document importer that can select HTML'),
    (r'DocumentType\.html|documentType\s*:\s*\.html|\.documentType\]\s*=\s*\.html', 'HTML document type'),
    (r'\bWKWebView\b|\bWebView\b|import\s+WebKit|loadHTMLString', 'WebKit'),
]
RTF = r'NSAttributedString\s*\(\s*rtf\s*:'
RTF_ALLOWED = {'Maccy/RichTextImport.swift', 'Maccy/IgnoreRules.swift'}

problems = []
rtf_sites = []
for path in sorted((ROOT / 'Maccy').rglob('*.swift')):
    relative = path.relative_to(ROOT).as_posix()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split('//', 1)[0]
        for pattern, reason in FORBIDDEN:
            if re.search(pattern, code):
                problems.append(f'{relative}:{number}: {reason}: {line.strip()}')
        if re.search(RTF, code):
            rtf_sites.append(relative)
            if relative not in RTF_ALLOWED:
                problems.append(f'{relative}:{number}: RTF import outside RichTextImport/IgnoreRules')

if problems:
    print('\n'.join(problems))
    sys.exit(1)
print(f'No WebKit or HTML document importer in app code; RTF imported only in {sorted(set(rtf_sites))}')
