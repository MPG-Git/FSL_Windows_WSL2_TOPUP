"""Run installed FSL on a COPY of the bundled phantom and compare actual images."""
from pathlib import Path
import argparse
import csv
import json
import os
import shutil
import subprocess
import nibabel as nib
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--outdir',type=Path,default=HERE/'output')
    out = ap.parse_args().outdir.resolve()
    if not os.environ.get('FSLDIR') or not shutil.which('topup') or not shutil.which('applytopup'):
        raise RuntimeError('Initialize FSL in this Linux/WSL shell first (see README)')
    out.mkdir(parents=True,exist_ok=False)
    work = out/'working_data'
    shutil.copytree(HERE/'data',work)
    command = ['bash',str(HERE.parents[1]/'Distortion_correction_with_blip_up_blip_down.bash'),
               '--root',str(work),'--runs','one two','--workers','2']
    with (out/'pipeline.log').open('w') as log:
        subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    rows = []
    for task in ['one','two']:
        name = f'sub-01_task-{task}_bold'
        source = nib.load(work/'sub-01/func'/f'{name}.nii.gz')
        corrected = nib.load(work/'sub-01/func'/f'{name}_blipUp_blipDown.nii.gz')
        a, b = source.get_fdata(), corrected.get_fdata()
        assert a.shape == b.shape == (32,32,32,2) and np.isfinite(b).all()
        assert np.allclose(source.affine,corrected.affine,atol=1e-6)
        relative = float(np.linalg.norm(a-b)/np.linalg.norm(a))
        assert relative < .05, f'Expected near-identity correction, got relative L2={relative}'
        shutil.copyfile(corrected.get_filename(),out/f'{task}_corrected.nii.gz')
        fig, axes = plt.subplots(1,3,figsize=(10,3.5),layout='constrained')
        for ax, volume, title in zip(axes,[a,b,b-a],['Original','Corrected','Difference']):
            im = ax.imshow(volume[:,:,16,0].T,origin='lower',cmap='viridis')
            ax.set_title(title); ax.set_axis_off(); fig.colorbar(im,ax=ax,shrink=.65)
        fig.savefig(out/f'{task}_preview.png',dpi=120); plt.close(fig)
        rows.append({'task':task,'shape':list(b.shape),'relative_L2_to_input':relative})
    (out/'metrics.json').write_text(json.dumps(rows,indent=2)+'\n')
    version = Path(os.environ['FSLDIR'])/'etc/fslversion'
    (out/'fsl_version.txt').write_text(version.read_text() if version.exists() else 'unknown\n')
    # Compare actual NIfTI voxel arrays with the shipped reference, not headers/timestamps.
    comparison = []
    for task in ['one','two']:
        a = nib.load(out/f'{task}_corrected.nii.gz')
        b = nib.load(HERE/'expected'/f'{task}_corrected.nii.gz')
        assert a.shape == b.shape and np.allclose(a.affine,b.affine,atol=1e-6)
        delta = float(np.linalg.norm(a.get_fdata()-b.get_fdata())/np.linalg.norm(b.get_fdata()))
        comparison.append({'task':task,'relative_L2_to_reference':delta,'tolerance':.05,'pass':delta<.05})
    with (out/'comparison.csv').open('w',newline='') as file:
        writer=csv.DictWriter(file,fieldnames=comparison[0].keys()); writer.writeheader(); writer.writerows(comparison)
    assert all(r['pass'] for r in comparison),'Reference mismatch; see comparison.csv'
    (out/'PASS.txt').write_text('PASS: both TOPUP runs preserved the zero-distortion phantom within 5% relative L2.\n')
    print(f'PASS: FSL synthetic example. Results: {out}')


if __name__ == '__main__':
    main()
