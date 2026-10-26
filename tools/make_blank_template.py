#!/usr/bin/env python3
"""Build a content-free, ordered MPC Sample schema resource from a local reference.

Developer utility only. The input reference and audio are never bundled.
"""
import argparse
import copy
import gzip
import json
from pathlib import Path
import zipfile


def make_blank(reference, output):
    if reference.suffix.lower() == '.zip':
        with zipfile.ZipFile(reference) as archive:
            members = [n for n in archive.namelist() if n.endswith('.xpj') and not n.startswith('__MACOSX/')]
            if len(members) != 1:
                raise ValueError('Expected one native reference project')
            raw = gzip.decompress(archive.read(members[0]))
    else:
        raw = gzip.decompress(reference.read_bytes())
    marker = raw.index(b'{')
    header = raw[:marker]
    expected_header = b'ACVS\n1.3.0.12\nSerialisableProjectData\njson\nLinux\n'
    if header != expected_header:
        raise ValueError('Unsupported reference format')
    source = json.loads(raw[marker:])
    data = source['data']
    if data['version'] != 28 or data['engineMode'] != 'Sample' or data['lastSavedProductIdentifier'] != 'AC50':
        raise ValueError('Unsupported reference schema')
    drums = [t for t in data['tracks'] if t['program']['type'] == 0]
    if len(drums) != 1:
        raise ValueError('Expected one drum track')
    blank = next(i for i in reversed(drums[0]['program']['drum']['instruments']) if all(not l['sampleFile'] for l in i['layersv']))

    def clean(value):
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                if key in ['samples', 'events', 'items', 'effects', 'arrangementClipMap', 'sharedClipMap']:
                    result[key] = []
                elif key in ['sampleFile', 'sampleName']:
                    result[key] = ''
                elif key == 'fxValue':
                    result[key] = 0.0
                else:
                    result[key] = clean(item)
            return result
        if isinstance(value, list):
            return [clean(v) for v in value]
        return value

    root = clean(source)
    data = root['data']
    track = next(t for t in data['tracks'] if t['program']['type'] == 0)
    blank = clean(blank)
    if 'noteCounters' in blank:
        blank['noteCounters'] = {key: 0 for key in blank['noteCounters']}
    track['program']['drum']['instruments'] = [copy.deepcopy(blank) for _ in range(128)]
    track['volume'] = 1.0
    track['mute'] = False
    track['transposition'] = 0
    for key in data['info']:
        data['info'][key] = ''
    data['info']['title'] = 'Untitled Kit'
    data['masterTempo'] = 120.0
    data['currentSequence'] = 0
    data['currentTrackIndex'] = data['tracks'].index(track)
    data['currentAssignablePadBank'] = 0
    # Retain a single silent sequence and a blank song, not reference titles.
    data['sequences'] = data['sequences'][:1]
    data['sequences'][0]['key'] = 0
    data['sequences'][0]['value']['name'] = 'Sequence 01'
    for song in data['songs']:
        song['name'] = '(unnamed)'
    # Source track/program labels are replaced consistently wherever referenced.
    names = {}
    for index, t in enumerate(data['tracks']):
        kind = t['program']['type']
        generic = 'Drum 001' if kind == 0 else ('Submix 1' if kind == 8 else 'Out 1/2' if index == 2 else 'Out 3/4')
        names[t['name']] = generic
        names[t['program']['name']] = generic
        t['name'] = generic
        t['program']['name'] = generic

    def neutral_names(value):
        if isinstance(value, dict):
            return {key: neutral_names(item) for key, item in value.items()}
        if isinstance(value, list):
            return [neutral_names(item) for item in value]
        if isinstance(value, str):
            return names.get(value, value)
        return value

    root = neutral_names(root)
    def audit(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ['samples', 'events', 'items', 'effects'] and item:
                    raise ValueError(f'Nonempty content remains: {key}')
                if key in ['sampleFile', 'sampleName'] and item:
                    raise ValueError('Audio reference remains')
                audit(item)
        elif isinstance(value, list):
            for item in value:
                audit(item)
        elif isinstance(value, str) and (value.lower().endswith(('.wav', '.aif', '.aiff', '.mp3')) or '/Users/' in value or '/Volumes/' in value):
            raise ValueError('Audio filename or personal filesystem path remains')
    audit(root)
    # Dict insertion order is part of the resource contract. Never sort these keys.
    encoded = header + json.dumps(root, ensure_ascii=False, separators=(',', ':')).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(gzip.compress(encoded, mtime=0))
    print(f'Built blank schema: {len(encoded):,} uncompressed bytes; {output.stat().st_size:,} packaged bytes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    make_blank(args.reference, args.output)
