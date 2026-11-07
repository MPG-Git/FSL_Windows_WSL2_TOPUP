import json
import os
from pathlib import Path
import subprocess
import sys
import nibabel as nib
import numpy as np

import tempfile
root = Path(tempfile.mkdtemp(prefix='topup smoke '))
repo = Path(__file__).resolve().parents[1]
script = repo/'Distortion_correction_with_blip_up_blip_down.bash'
fmap = root/'sub-01/fmap'; func=root/'sub-01/func'
fmap.mkdir(parents=True, exist_ok=True); func.mkdir(parents=True, exist_ok=True)
x,y,z=np.mgrid[-1:1:32j,-1:1:32j,-1:1:32j]
phantom=(100*np.exp(-4*(x*x+y*y+z*z))*(1+.1*x)).astype(np.float32)
affine=np.diag([3.,3.,3.,1.])
def save(path, data, direction):
    nib.save(nib.Nifti1Image(data, affine),path)
    Path(str(path).replace('.nii.gz','.json')).write_text(json.dumps({'PhaseEncodingDirection':direction,'TotalReadoutTime':.05}))
for i,task in enumerate(('one','two')):
    img=phantom*(1+i*.2)
    for direction,pedir in [('ap','j-'),('pa','j')]:
        save(fmap/f'sub-01_dir-{direction}_task-{task}_epi.nii.gz', img, pedir)
    save(func/f'sub-01_task-{task}_bold.nii.gz', np.stack([img,img],axis=-1),'j-')
base=['bash',str(script),'--root',str(root),'--runs','one two','--workers','2']
for suffix,args in [('dry',['--dry-run']),('actual',[])]:
    with (root/f'{suffix}.log').open('w') as log:
        result=subprocess.run(base+args,stdout=log,stderr=subprocess.STDOUT,timeout=600)
    assert result.returncode==0, f'{suffix} failed: {root/suffix}.log'
for task in ('one','two'):
    output=func/f'sub-01_task-{task}_bold_blipUp_blipDown.nii.gz'
    actual=nib.load(output).get_fdata(); source=nib.load(func/f'sub-01_task-{task}_bold.nii.gz').get_fdata()
    assert actual.shape==source.shape and np.isfinite(actual).all()
    # Identical reverse-encoding inputs should imply a near-zero field.
    relative=np.linalg.norm(actual-source)/np.linalg.norm(source)
    assert relative < .05, relative
    print(task,'relative error',relative,flush=True)
# Failures must reach the parent worker status (without running TOPUP).
bad=func/'sub-01_task-one_bold.json'; bad.write_text('{}')
with (root/'expected_failure.log').open('w') as log:
    result=subprocess.run(base+['--dry-run'],stdout=log,stderr=subprocess.STDOUT,timeout=30)
assert result.returncode!=0
assert subprocess.run(['bash',str(script),'--root'],capture_output=True,timeout=5).returncode==2
print('FSL actual, parallel, metadata rejection and CLI checks PASS',flush=True)

print("Artifacts:",root)
