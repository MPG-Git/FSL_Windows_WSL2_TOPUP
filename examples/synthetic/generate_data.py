"""Create two BIDS-like runs with identical opposing encodings (zero distortion)."""
from pathlib import Path
import argparse
import json
import nibabel as nib
import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("destination", nargs="?", type=Path, default=Path(__file__).parent / "data")
    root = ap.parse_args().destination
    root.mkdir(parents=True, exist_ok=False)
    fmap, func = root / "sub-01/fmap", root / "sub-01/func"
    fmap.mkdir(parents=True); func.mkdir(parents=True)
    x, y, z = np.mgrid[-1:1:32j, -1:1:32j, -1:1:32j]
    phantom = (100 * np.exp(-4*(x*x+y*y+z*z))*(1+.1*x)).astype(np.float32)
    affine = np.diag([3.,3.,3.,1.])
    def save(path, data, direction):
        nib.save(nib.Nifti1Image(data, affine), path)
        Path(str(path).replace('.nii.gz','.json')).write_text(json.dumps({
            'PhaseEncodingDirection': direction, 'TotalReadoutTime': .05}, indent=2)+'\n')
    for i, task in enumerate(('one','two')):
        img = phantom*(1+i*.2)
        for direction, pedir in [('ap','j-'),('pa','j')]:
            save(fmap/f'sub-01_dir-{direction}_task-{task}_epi.nii.gz',img,pedir)
        save(func/f'sub-01_task-{task}_bold.nii.gz',np.stack([img,img],axis=-1),'j-')
    (root/'dataset_description.json').write_text(json.dumps({
        'Name': 'Synthetic zero-distortion installation example', 'BIDSVersion': '1.9.0',
        'DatasetType': 'raw', 'Description': 'Generated Gaussian phantom; no participant data. Minimal inputs for this pipeline, not a full BIDS validation fixture.'},indent=2)+'\n')
    print(root)


if __name__ == '__main__':
    main()
