#!/usr/bin/env python3
"""Check the manually maintained Xcode graph and integration resource invariants."""
import collections
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Maccy.xcodeproj/project.pbxproj'
raw = PROJECT.read_text()
declarations = re.findall(r'^\s*([A-F0-9]{24}) /\*[^\n]*?\*/ = \{', raw, re.M)
assert len(declarations) == len(set(declarations)), 'Duplicate Xcode object IDs'
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(PROJECT)]))
objects = project['objects']
references = set(re.findall(r'\b[A-F0-9]{24}\b', re.sub(r'/\*.*?\*/', '', raw, flags=re.S)))
assert references <= objects.keys(), f'Dangling object IDs: {references - objects.keys()}'
paths = {}
parents = collections.Counter()

def walk(identifier, parent):
    obj = objects[identifier]
    if obj.get('sourceTree') not in (None, '<group>', 'SOURCE_ROOT'):
        return
    base = ROOT if obj.get('sourceTree') == 'SOURCE_ROOT' else parent
    path = base / obj.get('path', '')
    if obj['isa'] == 'PBXFileReference':
        assert path.exists(), f'Missing referenced file: {path}'
        paths[identifier] = path.relative_to(ROOT).as_posix()
    elif obj['isa'] in ('PBXGroup', 'PBXVariantGroup'):
        for child in obj.get('children', []):
            parents[child] += 1
            # Variant-group children include their own locale path.
            walk(child, base if obj['isa'] == 'PBXVariantGroup' else path)

walk(objects[project['rootObject']]['mainGroup'], ROOT)
for folder, target_name in [('Maccy', 'Maccy'), ('MaccyTests', 'MaccyTests')]:
    actual = {p.relative_to(ROOT).as_posix() for p in (ROOT / folder).rglob('*.swift')}
    refs = {identifier: path for identifier, path in paths.items() if path in actual}
    counts = collections.Counter(refs.values())
    assert set(counts) == actual, f'Unregistered Swift sources: {actual - counts.keys()}'
    assert all(n == 1 for n in counts.values()), f'Duplicate source references: {counts}'
    targets = [obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget' and obj['name'] == target_name]
    assert len(targets) == 1
    target_sources = []
    all_sources = []
    for obj in objects.values():
        if obj['isa'] == 'PBXSourcesBuildPhase':
            all_sources.extend(obj['files'])
    for phase_id in targets[0]['buildPhases']:
        phase = objects[phase_id]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            target_sources.extend(phase['files'])
    for ref, path in refs.items():
        builds = [key for key, obj in objects.items() if obj['isa'] == 'PBXBuildFile' and obj.get('fileRef') == ref]
        assert len(builds) == 1, f'Build-file count for {path}: {len(builds)}'
        assert parents[ref] == 1, f'Group membership for {path}: {parents[ref]}'
        assert target_sources.count(builds[0]) == 1, f'Target membership for {path}'
        assert all_sources.count(builds[0]) == 1, f'Duplicate build-phase entry for {path}'
    print(f'{folder}: {len(actual)} Swift sources, each registered once in its target')

strings = list((ROOT / 'Maccy').rglob('*.strings'))
for path in strings:
    subprocess.run(['plutil', '-lint', str(path)], check=True, capture_output=True)
    if path.parent.name == 'en.lproj':
        keys = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', path.read_text(), re.M)
        assert len(keys) == len(set(keys)), f'Duplicate English keys: {path}'
commands = 0
for path in (ROOT / 'Maccy/Settings').glob('*.lproj/AdvancedSettings.strings'):
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    for key, modes in [('TurnOffShellScript', ['paused', 'capturing']), ('TurnOffNextShellScript', ['skipNext'])]:
        value = data.get(key, '')
        if value:
            commands += 1
            assert '<BUNDLE_ID>' in value and 'org.p0deje' not in value, str(path)
            assert all(f'captureMode {mode}' in value for mode in modes), str(path)
print(f'{len(strings)} valid strings files, unique English keys, {commands} captureMode command templates')
print('No duplicate project IDs, dangling references or missing referenced files')
