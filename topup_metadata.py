"""Validate the supported j-axis acquisition before running TOPUP."""
import json
from pathlib import Path
import sys


def read_metadata(path):
    path = str(path)
    sidecar = Path(path[:-7] + '.json' if path.endswith('.nii.gz') else path[:-4] + '.json')
    with sidecar.open() as stream:
        meta = json.load(stream)
    direction = meta.get('PhaseEncodingDirection')
    readout = meta.get('TotalReadoutTime')
    if direction not in ('j', 'j-'):
        raise ValueError(f'{sidecar}: PhaseEncodingDirection must be j or j- for this workflow')
    if isinstance(readout, bool) or not isinstance(readout, (int, float)) or not 0 < readout < 1:
        raise ValueError(f'{sidecar}: supply TotalReadoutTime in seconds (0 < value < 1)')
    return direction, readout


def acquisition(ap, pa, bold, override=''):
    first, second, target = read_metadata(ap), read_metadata(pa), read_metadata(bold)
    if first[0] == second[0]:
        raise ValueError('The two field maps must have opposite phase-encoding directions')
    if override:
        if override not in ('j', 'j-'):
            raise ValueError('Direction override must be j or j-')
        target = (override, target[1])
    match = [i + 1 for i, row in enumerate((first, second))
             if row[0] == target[0] and abs(row[1] - target[1]) < 1e-7]
    if not match:
        raise ValueError('BOLD direction/readout must match one field-map acquisition')
    return first, second, match[0]


if __name__ == '__main__':
    try:
        first, second, index = acquisition(*sys.argv[1:])
        print(first[1], second[1], -1 if first[0] == 'j-' else 1,
              -1 if second[0] == 'j-' else 1, index)
    except (ValueError, OSError, TypeError) as error:
        sys.exit(f'Acquisition metadata error: {error}')
