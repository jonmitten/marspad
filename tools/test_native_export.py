#!/usr/bin/env python3
"""Integration checks against a caller-supplied native reference; no proprietary fixture is bundled."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import wave
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('template', type=Path)
    args = parser.parse_args()
    binary, template = args.binary.resolve(), args.template.resolve()
    original_hash = hashlib.sha256(template.read_bytes()).digest()
    with tempfile.TemporaryDirectory(prefix='marspad-export-test-') as temp:
        root = Path(temp)
        source = root / 'sounds'; source.mkdir()
        output = root / 'out'; output.mkdir()
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

        def export(values, reference=template, ok=True):
            plan = root / 'test.marspad'
            plan.write_text(json.dumps({'version': 1, 'name': 'Integration Test', 'pads': values}))
            before = set(output.iterdir())
            result = subprocess.run([str(binary), '--export-mpc', str(plan), str(reference), str(output)], capture_output=True, text=True, timeout=60)
            if not ok:
                assert result.returncode != 0, result.stdout
                assert set(output.iterdir()) == before, 'Failed export left incomplete output'
                return
            assert result.returncode == 0, result.stderr
            folder = Path(result.stdout.strip())
            project = next(folder.glob('*.xpj'))
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
            for i, item in enumerate(values):
                layers = instruments[i]['layersv']
                assert len(layers) == 8
                assert all(not l['sampleFile'] for l in layers[1:])
                if item is None:
                    assert not layers[0]['sampleFile']
                    continue
                name = f'{chr(65+i//16)}{i%16+1:02d}'
                assert layers[0]['sampleFile'] == name + '.wav'
                assert layers[0]['sampleName'] == name
                with wave.open(item['path']) as original, wave.open(str(audio_folder / (name + '.wav'))) as actual:
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

        export(pads)
        sparse = [None] * 128
        for i in [0, 15, 16, 63, 127]: sparse[i] = pads[i]
        export(sparse)
        # Raw XPJ templates work as well as archives.
        with zipfile.ZipFile(template) as archive:
            name = next(n for n in archive.namelist() if n.endswith('.xpj'))
            raw_reference = root / 'reference.xpj'
            raw_reference.write_bytes(archive.read(name))
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
        print('PASS: 128-pad / 8-bank exports; sparse banks; archive and raw templates; 24-bit PCM payload/rate/channel/frame accuracy; no stale samples/events; independent reference inspection; failures clean up; originals unchanged')


if __name__ == '__main__':
    main()
