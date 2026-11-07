# FSL TOPUP on Windows through WSL2

This is a Bash/Python workflow for FSL, not an EEGLAB plugin. It needs WSL2
with a Linux distribution, Bash, Python 3, and a working FSL installation.
Use the [official FSL Windows instructions](https://fsl.fmrib.ox.ac.uk/fsl/docs/install/windows.html).
Install FSL inside the Linux filesystem and initialize its environment in
the WSL terminal. The workflow does not install or modify FSL.

## Check setup

Run these commands inside WSL, from this repository's directory:

```bash
command -v topup applytopup fslmaths fslmerge fslval python3
bash -n Distortion_correction_with_blip_up_blip_down.bash
python3 -m unittest discover -s tests
bash Distortion_correction_with_blip_up_blip_down.bash --help
```

The repository forces LF line endings for shell files, including Windows
checkouts. Keep `topup_metadata.py` alongside the Bash script.

## Input layout and acquisition metadata

For each requested task, the workflow looks for:

```
sub-01/[ses-01/]func/sub-01[_ses-01]_task-rest_bold.nii.gz
sub-01/[ses-01/]fmap/sub-01[_ses-01]_task-rest_dir-ap_epi.nii.gz
sub-01/[ses-01/]fmap/sub-01[_ses-01]_task-rest_dir-pa_epi.nii.gz
```

Uncompressed `.nii` inputs and the legacy `dir-ap_task-rest` entity order are
also accepted. A keyword fallback is allowed only when exactly one file
matches each direction. Ambiguous files must be renamed or selected by a
more specific keyword. Multiple `run-`, `echo-`, or `acq-` variants are not
resolved automatically. Task names passed via `--runs` refer to task entities.

Each NIfTI must have a JSON sidecar containing `PhaseEncodingDirection` and
`TotalReadoutTime` in seconds. Only opposite **j/j-** field-map acquisitions
are supported. Directions come from metadata, not AP/PA filename assumptions.
The BOLD direction/readout must match one field map. Missing, ambiguous or
unsupported metadata fails; the script never guesses the readout time.
Images must already have compatible spatial geometry and acquisition setup.

## Run

```bash
bash Distortion_correction_with_blip_up_blip_down.bash --root /mnt/d/my_BIDS --runs 'rest doors1' --workers 2 --topup-nthr 1 --dry-run
bash Distortion_correction_with_blip_up_blip_down.bash --root /mnt/d/my_BIDS --runs 'rest doors1' --workers 2 --topup-nthr 1
```

A dry run checks file selection and metadata and writes logs/status only.
Each actual task gets a unique work directory, preventing concurrent tasks
or old intermediates from mixing. Corrected images and text summaries are
copied next to the source BOLD files with `_blipUp_blipDown`/`_blipAnB` suffixes.
Rerunning a task replaces those derived outputs; the source BOLD is retained.
Worker errors cause a nonzero batch exit status. Missing requested BOLD files
are recorded as SKIP, so also inspect the status TSV for intended coverage.

## Actual FSL smoke test

```bash
"$FSLDIR/bin/python" tests/smoke_actual_fsl.py
```

This generates two small synthetic BIDS tasks in a temporary directory,
runs actual TOPUP/applytopup concurrently, checks near-zero distortion for
identical opposing-encoding images, and verifies failure propagation and CLI
validation. The test requires NumPy and NiBabel (available in the FSL Python
environment). It does not validate distortion correction on real participant
data; review field maps, acquisition metadata and before/after images.

## Downloadable synthetic example

[Run the bundled synthetic example](examples/synthetic/README.md) to check your setup against
included reference outputs. It contains actual input files, a one-command runner,
expected tables/plots, and numerical comparisons that report PASS or a mismatch.
The example guide links to the ZIP of this review branch, including the readiness fixes.
