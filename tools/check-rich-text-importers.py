#!/usr/bin/env python3
"""Fail if app code imports a document or decodes an image outside the approved paths.

Clipboard content is untrusted (A7).
- HTML is only ever scanned by ClipboardHTMLText. No app code may hand copied
  data to a document importer (`NSAttributedString`/`NSMutableAttributedString`
  initialisers or `read(from:)` taking `data:`, `url:`, `html:`, `docFormat:`,
  `rtf:`, `rtfd:`, `rtfdFileWrapper:`, `contentsOf:`, `path:`, `fileURL:`),
  except Maccy/RichTextImport.swift, and every call there must pass an
  explicit `.documentType` of `.rtf`: without one AppKit sniffs the bytes and
  may pick its WebKit-backed HTML importer, which can load remote resources.
- WebKit, Quick Look previews and PDFKit are not used at all.
- Images are decoded only by Maccy/ValidatedImage.swift (ImageIO, every image
  checked first); `NSImage(data:)`, `NSImage(contentsOf:)`,
  `NSBitmapImageRep(data:)`, `CGImageSourceCreate...` and Vision handlers
  taking data or a URL are rejected elsewhere.
- The clipboard watcher (Maccy/Clipboard.swift) reads no pasteboard data
  itself (`string(forType:)`, `data(forType:)`, `propertyList(forType:)`,
  `readObjects`): every value it uses comes from the bounded snapshot in
  Maccy/PasteboardCopyRead.swift or from the ignore-rule reader.

Each file is scanned as a whole with comments and string literals blanked
out (line breaks kept, so a call split over several lines is still seen and
line numbers stay right); code inside string interpolation is scanned.

`--self-test` runs the guard on tools/importer-guard-fixtures: every file
under reject/ must fail and every file under allow/ must pass. A fixture can
name the app path it stands for in a first-line comment
`// guard-fixture-path: Maccy/RichTextImport.swift`.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tools/importer-guard-fixtures'
RICH_TEXT_FILE = 'Maccy/RichTextImport.swift'
IMAGE_FILE = 'Maccy/ValidatedImage.swift'
WATCHER_FILE = 'Maccy/Clipboard.swift'
PASTEBOARD_READ = re.compile(
    r'\.\s*(?:string|data|propertyList)\s*\(\s*forType\s*:|\breadObjects\s*\(')

DOCUMENT_ARGUMENTS = r'(?:data|url|html|docFormat|rtf|rtfd|rtfdFileWrapper|contentsOf|path|fileURL)'
ATTRIBUTED_INIT = re.compile(
    r'\b(?:NS(?:Mutable)?AttributedString)\s*(?:\.\s*init\s*)?\(\s*' + DOCUMENT_ARGUMENTS + r'\s*:')
READ_FROM = re.compile(r'\.\s*read\s*\(\s*from\s*:')
EVERYWHERE = [
    (re.compile(r'\bWKWebView\b|\bWebView\b|\bimport\s+WebKit\b|\bloadHTMLString\b'), 'WebKit'),
    (re.compile(r'\bQLPreview\w*|\bimport\s+Quick[Ll]ook\w*'), 'Quick Look preview'),
    (re.compile(r'\bPDFDocument\b|\bPDFView\b|\bimport\s+PDFKit\b'), 'PDFKit'),
    (re.compile(r'DocumentType\s*\.\s*html\b|documentType\s*:\s*\.\s*html\b|\]\s*=\s*\.\s*html\b'),
     'HTML document type'),
    (re.compile(r'\bVNImageRequestHandler\s*\(\s*(?:data|url)\s*:'), 'Vision decoding image data directly'),
]
IMAGE_DECODERS = [
    re.compile(r'\bNSImage\s*(?:\.\s*init\s*)?\(\s*(?:data|contentsOf|contentsOfFile|byReferencing\w*|pasteboard)\s*:'),
    re.compile(r'\bNSBitmapImageRep\s*(?:\.\s*init\s*)?\(\s*data\s*:'),
    re.compile(r'\bNSBitmapImageRep\s*\.\s*imageReps?\s*\('),
    re.compile(r'\bNSImageRep\s*\.\s*imageReps?\s*\('),
    re.compile(r'\bCIImage\s*(?:\.\s*init\s*)?\(\s*(?:data|contentsOf)\s*:'),
    re.compile(r'\bCGImageSourceCreate\w*'),
]


STRING_START = re.compile(r'(#*)("""|")')


def strip(source):
    """Blanks comments and string literals, keeping line breaks and the code
    inside string interpolation."""
    out = []
    i = 0
    n = len(source)

    def blank(text):
        return ''.join('\n' if c == '\n' else ' ' for c in text)

    def string_literal(i, hashes, multiline):
        """Returns the end index of a string literal starting at i (after the
        opening delimiter), appending blanked text and interpolated code."""
        closing = ('"""' if multiline else '"') + '#' * hashes
        interpolation = '\\' + '#' * hashes + '('
        while i < n:
            if source.startswith(closing, i):
                out.append(' ' * len(closing))
                return i + len(closing)
            if source.startswith(interpolation, i):
                out.append(' ' * len(interpolation))
                i = code(i + len(interpolation), until_paren=True)
                continue
            if hashes == 0 and source[i] == '\\' and i + 1 < n:
                out.append(blank(source[i:i + 2]))
                i += 2
                continue
            out.append('\n' if source[i] == '\n' else ' ')
            i += 1
        return i

    def code(i, until_paren=False):
        depth = 0
        while i < n:
            c = source[i]
            if until_paren:
                if c == '(':
                    depth += 1
                elif c == ')':
                    if depth == 0:
                        out.append(' ')
                        return i + 1
                    depth -= 1
            if source.startswith('//', i):
                end = source.find('\n', i)
                end = n if end == -1 else end
                out.append(' ' * (end - i))
                i = end
                continue
            if source.startswith('/*', i):
                nesting = 0
                start = i
                while i < n:
                    if source.startswith('/*', i):
                        nesting += 1
                        i += 2
                    elif source.startswith('*/', i):
                        nesting -= 1
                        i += 2
                        if nesting == 0:
                            break
                    else:
                        i += 1
                out.append(blank(source[start:i]))
                continue
            match = STRING_START.match(source, i) if c in '#"' else None
            if match:
                hashes = len(match.group(1))
                out.append(' ' * len(match.group(0)))
                i = string_literal(i + len(match.group(0)), hashes, match.group(2) == '"""')
                continue
            out.append(c)
            i += 1
        return i

    code(0)
    return ''.join(out)


def call_extent(text, open_paren):
    """The text of a call's argument list starting at `open_paren`."""
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == '(':
            depth += 1
        elif text[index] == ')':
            depth -= 1
            if depth == 0:
                return text[open_paren:index + 1]
    return text[open_paren:]


def check(relative, source):
    problems = []
    code = strip(source)

    def report(match, reason):
        line = code.count('\n', 0, match.start()) + 1
        excerpt = source.splitlines()[line - 1].strip() if source.splitlines() else ''
        problems.append(f'{relative}:{line}: {reason}: {excerpt}')

    for match in ATTRIBUTED_INIT.finditer(code):
        if relative != RICH_TEXT_FILE:
            report(match, f'document importer outside {RICH_TEXT_FILE}')
            continue
        arguments = call_extent(code, code.index('(', match.start()))
        if not re.match(r'\(\s*data\s*:', arguments) or \
                not re.search(r'\.\s*documentType\s*:\s*(?:NSAttributedString\s*\.\s*DocumentType)?\s*\.\s*rtf\b',
                              arguments):
            report(match, 'document import without an explicit .documentType: .rtf')
    for match in READ_FROM.finditer(code):
        report(match, 'document importer (read(from:))')
    for pattern, reason in EVERYWHERE:
        for match in pattern.finditer(code):
            report(match, reason)
    if relative != IMAGE_FILE:
        for pattern in IMAGE_DECODERS:
            for match in pattern.finditer(code):
                report(match, f'image decoded outside {IMAGE_FILE}')
    if relative == WATCHER_FILE:
        for match in PASTEBOARD_READ.finditer(code):
            report(match, 'pasteboard read in the watcher outside the bounded snapshot')
    return problems


def fixture_path(path):
    first = path.read_text().splitlines()[:1]
    match = re.match(r'\s*//\s*guard-fixture-path:\s*(\S+)', first[0]) if first else None
    return match.group(1) if match else 'Maccy/Fixture.swift'


def self_test():
    failures = []
    rejected = sorted((FIXTURES / 'reject').glob('*.swift'))
    allowed = sorted((FIXTURES / 'allow').glob('*.swift'))
    assert rejected and allowed, 'no guard fixtures found'
    for path in rejected:
        if not check(fixture_path(path), path.read_text()):
            failures.append(f'not rejected: {path.relative_to(ROOT)}')
    for path in allowed:
        problems = check(fixture_path(path), path.read_text())
        if problems:
            failures.append(f'rejected: {path.relative_to(ROOT)}: {problems}')
    if failures:
        print('\n'.join(failures))
        sys.exit(1)
    print(f'Guard self-test: {len(rejected)} fixtures rejected, {len(allowed)} allowed')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
        return
    problems = []
    for path in sorted((ROOT / 'Maccy').rglob('*.swift')):
        problems += check(path.relative_to(ROOT).as_posix(), path.read_text())
    if problems:
        print('\n'.join(problems))
        sys.exit(1)
    print(f'No WebKit, Quick Look, PDFKit or unchecked document import in app code; '
          f'documents imported only in {RICH_TEXT_FILE} (explicit RTF), images decoded only in {IMAGE_FILE}; '
          f'no direct pasteboard reads in {WATCHER_FILE}')


if __name__ == '__main__':
    main()
