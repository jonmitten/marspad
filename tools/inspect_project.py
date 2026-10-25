#!/usr/bin/env python3
"""Read-only inspection of an MPC Sample project ZIP. No extraction or mutation."""
import argparse
import gzip
import json
from pathlib import PurePosixPath
import zipfile


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f'Archive integrity failure: {bad}')
        projects = [n for n in archive.namelist() if n.lower().endswith('.xpj') and not n.startswith('__MACOSX/')]
        if len(projects) != 1:
            raise ValueError('Expected exactly one XPJ file')
        project = projects[0]
        raw = gzip.decompress(archive.read(project))
        marker = raw.index(b'{')
        header = raw[:marker].decode('utf-8')
        if 'SerialisableProjectData\njson\n' not in header:
            raise ValueError('Unrecognized project header')
        data = json.loads(raw[marker:])['data']
        folder = str(PurePosixPath(project).with_suffix('')) + '_[ProjectData]/'
        entries = set(archive.namelist())
        missing = set()
        assignments = []
        def visit(obj):
            if isinstance(obj, dict):
                if isinstance(obj.get('path'), str) and obj['path'].lower().endswith('.wav'):
                    if folder + obj['path'] not in entries:
                        missing.add(obj['path'])
                if isinstance(obj.get('sampleFile'), str) and obj['sampleFile']:
                    if folder + obj['sampleFile'] not in entries:
                        missing.add(obj['sampleFile'])
                for value in obj.values():
                    visit(value)
            elif isinstance(obj, list):
                for value in obj:
                    visit(value)
        visit(data)
        for track_index, track in enumerate(data.get('tracks', [])):
            instruments = track.get('program', {}).get('drum', {}).get('instruments', [])
            for index, instrument in enumerate(instruments):
                for layer_index, layer in enumerate(instrument.get('layersv', [])):
                    if layer.get('sampleFile'):
                        assignments.append({'track': track_index + 1, 'instrument_index': index,
                                            'inferred_pad': f'{chr(65 + index // 16)}{index % 16 + 1:02d}',
                                            'layer': layer_index + 1, 'file': layer['sampleFile']})
        return {'header': header.splitlines(), 'project': project,
                'wav_count': sum(n.lower().endswith('.wav') for n in entries),
                'missing_references': sorted(missing), 'assignments': assignments,
                'note': 'Pad labels inferred from instrument order; confirm against hardware. Inspection does not validate generated exports.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project_zip')
    args = parser.parse_args()
    print(json.dumps(inspect(args.project_zip), indent=2))
