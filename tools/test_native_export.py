#!/usr/bin/env python3
"""Integration checks against a built-in blank project or an optional caller-supplied reference."""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path
import struct
import subprocess
import tempfile
import unicodedata
import wave
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('template', type=Path, nargs='?')
    args = parser.parse_args()
    binary = args.binary.resolve()
    template = args.template.resolve() if args.template else Path(__file__).resolve().parents[1] / 'Sources/MarsPad/Resources/BlankProject.json.gz'
    reference_argument = str(template) if args.template else 'builtin'
    if zipfile.is_zipfile(template):
        with zipfile.ZipFile(template) as archive:
            packed = archive.read(next(n for n in archive.namelist() if n.endswith('.xpj')))
    else:
        packed = template.read_bytes()
    original_hash = hashlib.sha256(template.read_bytes()).digest()
    with tempfile.TemporaryDirectory(prefix='marspad-export-test-') as temp:
        root = Path(temp)
        source = root / 'sounds'; source.mkdir()
        output = root / 'out'; output.mkdir()
        # A no-change archive must preserve serialization order and scalar tokens.
        # Ordinary JSON equality would miss the sorted-key rewrite in older builds.
        roundtrip = root / 'roundtrip-native.txt'
        result = subprocess.run([str(binary), '--roundtrip-native', reference_argument, str(roundtrip)], capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        native = gzip.decompress(packed)
        if not args.template:
            blank = json.loads(native[native.index(b'{'):])['data']
            drums = [t for t in blank['tracks'] if t['program']['type'] == 0]
            instruments = drums[0]['program']['drum']['instruments']
            assert len(drums) == 1 and len(instruments) == 128
            assert all(len(i['layersv']) == 8 for i in instruments)
            def audit(value):
                if isinstance(value, dict):
                    for key, item in value.items():
                        if key in ['samples', 'events', 'items', 'effects', 'sampleFile', 'sampleName']:
                            assert not item, f'Bundled project contains content: {key}'
                        audit(item)
                elif isinstance(value, list):
                    for item in value: audit(item)
                elif isinstance(value, str):
                    assert '/Users/' not in value and '/Volumes/' not in value
                    assert not value.lower().endswith(('.wav', '.aif', '.aiff', '.mp3'))
            audit(blank)
        def tokens(raw):
            return re.findall(rb'"(?:\\.|[^"\\])*"|[^\s"{},:\[\]]+|[{},:\[\]]', raw)
        assert tokens(native) == tokens(roundtrip.read_bytes()), 'Native field order/scalar spellings changed'
        pads = []
        for i in range(128):
            path = source / f'sound-{i:03d}.wav'
            channels = 1 + i % 2
            rate = [44100, 48000, 96000][i % 3]
            # Distinct constant amplitudes identify both pad ordering and audio payload.
            with wave.open(str(path), 'wb') as audio:
                audio.setparams((channels, 2, rate, 100 + i, 'NONE', 'not compressed'))
                audio.writeframes(struct.pack('<h', 100 + i) * (100 + i) * channels)
            pads.append({'path': str(path), 'collection': 'Synthetic', 'category': 'Other'})
        source_hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in source.iterdir()}

        def export(values, reference=reference_argument, ok=True, kit_name='Integration Test'):
            plan = root / 'test.marspad'
            plan.write_text(json.dumps({'version': 1, 'name': kit_name, 'pads': values}))
            before = set(output.iterdir())
            result = subprocess.run([str(binary), '--export-mpc', str(plan), str(reference), str(output)], capture_output=True, text=True, timeout=60)
            if not ok:
                assert result.returncode != 0, result.stdout
                assert set(output.iterdir()) == before, 'Failed export left incomplete output'
                return
            assert result.returncode == 0, result.stderr
            folder = Path(result.stdout.strip())
            project = next(folder.glob('*.xpj'))
            assert project.stem == folder.name
            assert '/' not in project.name and ':' not in project.name and '?' not in project.name
            if kit_name == 'Integration Test':
                assert project.stem == 'Integration Test' or project.stem.startswith('Integration Test-')
            notes = (folder / 'READ ME.txt').read_text()
            assert 'MPC-Sample/Projects' in notes and project.name in notes
            assert 'Do not copy this outer export folder' in notes
            raw = gzip.decompress(project.read_bytes())
            assert raw.startswith(b'ACVS\n1.3.0.12\nSerialisableProjectData\njson\nLinux\n')
            data = json.loads(raw[raw.index(b'{'):])['data']
            track = next(t for t in data['tracks'] if t['program']['type'] == 0)
            instruments = track['program']['drum']['instruments']
            assert len(instruments) == 128
            audio_folder = folder / (project.stem + '_[ProjectData]')
            expected = sum(s is not None for s in values)
            assert len(list(audio_folder.glob('*.wav'))) == expected
            assert len(data['samples']) == len(track['samples']) == expected
            export_report = json.loads((folder / 'Export Report.json').read_text())
            report_by_pad = {entry['pad']: entry for entry in export_report['assignments']}
            display_names = [entry['name'].lower() for entry in data['samples']]
            assert len(display_names) == len(set(display_names)), 'Duplicate native sample identities'
            for i, item in enumerate(values):
                layers = instruments[i]['layersv']
                assert len(layers) == 8
                assert all(not l['sampleFile'] for l in layers[1:])
                if item is None:
                    assert not layers[0]['sampleFile']
                    continue
                name = f'{chr(65+i//16)}{i%16+1:02d}'
                original_name = Path(item['path']).stem
                duplicate = sum(v is not None and Path(v['path']).stem.lower() == original_name.lower() for v in values) > 1
                expected_name = original_name + (f' [{name}]' if duplicate else '')
                record = report_by_pad[name]
                filename = layers[0]['sampleFile']
                assert filename.startswith(name + '_') and filename.endswith('.wav')
                assert len(filename) <= 128 and not any(c in filename for c in '/\\:*?"<>|')
                assert unicodedata.normalize('NFC', layers[0]['sampleName']) == unicodedata.normalize('NFC', expected_name)
                assert unicodedata.normalize('NFC', record['sourceName']) == unicodedata.normalize('NFC', original_name)
                assert unicodedata.normalize('NFC', record['sampleName']) == unicodedata.normalize('NFC', expected_name)
                assert record['file'] == filename
                assert any(unicodedata.normalize('NFC', e['name']) == unicodedata.normalize('NFC', expected_name) and e['path'] == filename for e in data['samples'])
                assert any(unicodedata.normalize('NFC', e['name']) == unicodedata.normalize('NFC', expected_name) and e['path'] == filename for e in track['samples'])
                with wave.open(item['path']) as original, wave.open(str(audio_folder / filename)) as actual:
                    assert actual.getsampwidth() == 3
                    assert actual.getnchannels() == original.getnchannels()
                    assert actual.getframerate() == original.getframerate()
                    assert actual.getnframes() == original.getnframes()
                    assert layers[0]['sliceInfo']['End'] == original.getnframes() - 1
                    src = int.from_bytes(original.readframes(1)[:2], 'little', signed=True)
                    dst = int.from_bytes(actual.readframes(1)[:3], 'little', signed=True)
                    assert abs(dst - src * 256) <= 1, (i, src, dst)
            def walk(value):
                if isinstance(value, dict):
                    for key, val in value.items():
                        if key in ['events', 'items', 'effects']: assert val == [], key
                        if key in ['path', 'sampleFile'] and isinstance(val, str) and val:
                            assert (audio_folder / val).is_file() and '/' not in val
                        walk(val)
                elif isinstance(value, list):
                    for val in value: walk(val)
            walk(data)
            # Independently cross-check the project using the archive inspector.
            check_zip = root / 'generated.zip'
            with zipfile.ZipFile(check_zip, 'w') as z:
                for file in folder.rglob('*'):
                    if file.is_file(): z.write(file, file.relative_to(folder))
            from inspect_project import inspect
            report = inspect(check_zip)
            assert not report['missing_references']
            assert len(report['assignments']) == expected
            return project

        first_project = export(pads)
        assert first_project.name == 'Integration Test.xpj'
        first_project_hash = hashlib.sha256(first_project.read_bytes()).digest()
        # Same basenames from different folders must retain distinct identities.
        import shutil
        collisions = [None] * 128
        for i, basename in [(0, 'Kick'), (1, 'kick'), (15, 'Café Hat #1'), (16, 'Unsafe : name?'), (127, 'Long' * 50)]:
            folder = root / f'names-{i}'; folder.mkdir()
            path = folder / (basename + '.wav')
            shutil.copyfile(pads[i]['path'], path)
            collisions[i] = dict(pads[i], path=str(path))
        second_project = export(collisions)
        assert second_project.name == 'Integration Test-2.xpj'
        assert hashlib.sha256(first_project.read_bytes()).digest() == first_project_hash
        export(collisions, kit_name=' ../Unsafe: Kit? ')
        export(collisions, kit_name='')
        sparse = [None] * 128
        for i in [0, 15, 16, 63, 127]: sparse[i] = pads[i]
        export(sparse)
        # Raw XPJ templates work as well as archives.
        raw_reference = root / 'reference.xpj'
        raw_reference.write_bytes(packed)
        export(sparse, raw_reference)
        missing = sparse.copy(); missing[1] = dict(pads[1], path=str(root / 'missing.wav'))
        export(missing, ok=False)
        export([None] * 128, ok=False)
        export(pads[:16], ok=False)
        bad_reference = root / 'invalid.xpj'; bad_reference.write_bytes(b'invalid gzip')
        export(sparse, bad_reference, ok=False)
        unsupported = source / 'unsupported.wav'
        with wave.open(str(unsupported), 'wb') as audio:
            audio.setparams((1, 2, 22050, 10, 'NONE', 'not compressed'))
            audio.writeframes(b'\x00\x00' * 10)
        values = sparse.copy(); values[0] = dict(pads[0], path=str(unsupported))
        export(values, ok=False)
        assert hashlib.sha256(template.read_bytes()).digest() == original_hash
        assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in source_hashes.items())
        print('PASS: token-identical native round-trip; kit-based project names; non-overwriting numbered exports; SD placement notes; original/Unicode/duplicate/long sample names; safe filenames; 128-pad / 8-bank exports; sparse banks; archive and raw templates; 24-bit PCM payload/rate/channel/frame accuracy; no stale samples/events; independent reference inspection; failures clean up; originals unchanged')


if __name__ == '__main__':
    main()
