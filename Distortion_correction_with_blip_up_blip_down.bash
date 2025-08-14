#!/usr/bin/env bash
# Batch TOPUP pipeline (AP/PA blip-up/blip-down) with QA + PARALLELISM + FLEXIBLE BLIP DETECTION
#
# Outputs per BOLD:
#   <boldstem>_blipUp_blipDown.nii.gz   (corrected BOLD)
#   <boldstem>_blipAnB.txt              (metrics summary)
# Intermediates/QA in $ROOT/topup_work_<sub>_<ses>/
#
# USAGE:
#   bash run_topup_batch.sh \
#     --root /path/to/BIDS \
#     --runs "doors1 doors2 rs" \
#     --workers 4 \
#     --topup-nthr 2 \
#     --ap-keys "ap blipa" \
#     --pa-keys "pa blipb" \
#     [--pedir-override j- | j] \
#     [--dry-run]
#
# Quick examples:
#   ROOT=/mnt/f/UIC_DDP_Data/BIDS_DDP BOLD_RUNS="doors1 rs" N_WORKERS=3 bash run_topup_batch.sh
#   bash run_topup_batch.sh --root /data/BIDS --runs "doors1 rs" --workers 6 --topup-nthr 2
#
# NOTES:
# - Prefers BIDS fmap files like: sub-XX/ses-YY/fmap/*dir-ap*_epi.nii[.gz] and *dir-pa*.
# - If missing, scans fmap/ for filenames containing AP/PA keyword sets (case-insensitive).
# - Reads TotalReadoutTime from the AP JSON when available; defaults to 0.050s otherwise.
# - Determines applytopup inindex using PEDIR override > BOLD JSON > defaults to j- (index=1).
# - Works with sessionless BIDS (no ses-*).
#
set -o pipefail

# ---------- Defaults (overridable by CLI or env) ----------
ROOT="${ROOT:-/mnt/f/UIC_DDP_Data/BIDS_DDP}"
BOLD_RUNS="${BOLD_RUNS:-doors1 doors2 rs}"
PEDIR_OVERRIDE="${PEDIR_OVERRIDE:-}"     # j- or j to force applytopup inindex
N_WORKERS="${N_WORKERS:-1}"
TOPUP_NTHR="${TOPUP_NTHR:-1}"
AP_KEYS_DEFAULT="ap blipa"
PA_KEYS_DEFAULT="pa blipb"
DRY_RUN=0
# ---------------------------------------------------------

print_help() {
cat <<EOF
run_topup_batch.sh — Batch FSL TOPUP for BIDS datasets (AP/PA), with flexible blip detection.

Options:
  --root PATH            BIDS root (default: $ROOT)
  --runs "A B C"         Space-separated task list (default: "$BOLD_RUNS")
  --workers N            Parallel jobs (subjects/sessions/runs) (default: $N_WORKERS)
  --topup-nthr N         Threads per TOPUP job (avoid oversubscription) (default: $TOPUP_NTHR)
  --pedir-override VAL   Force BOLD PhaseEncodingDirection: j- or j (default: unset)
  --ap-keys  "k1 k2"     Keywords for AP (fallback scan) (default: "$AP_KEYS_DEFAULT")
  --pa-keys  "k1 k2"     Keywords for PA (fallback scan) (default: "$PA_KEYS_DEFAULT")
  --dry-run              List planned tasks & detected blips, do not run TOPUP
  -h | --help            Show this help

Env overrides (same names): ROOT, BOLD_RUNS, N_WORKERS, TOPUP_NTHR, PEDIR_OVERRIDE

Examples:
  ROOT=/data/BIDS N_WORKERS=4 bash run_topup_batch.sh
  bash run_topup_batch.sh --root /data/BIDS --runs "doors1 rs" --workers 6 --topup-nthr 2
EOF
}

# ---------- CLI parsing ----------
AP_KEYS=($AP_KEYS_DEFAULT)
PA_KEYS=($PA_KEYS_DEFAULT)
while (( "$#" )); do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --runs) BOLD_RUNS="$2"; shift 2;;
    --workers) N_WORKERS="$2"; shift 2;;
    --topup-nthr) TOPUP_NTHR="$2"; shift 2;;
    --pedir-override) PEDIR_OVERRIDE="$2"; shift 2;;
    --ap-keys) AP_KEYS=($2); shift 2;;
    --pa-keys) PA_KEYS=($2); shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) print_help; exit 0;;
    *) echo "Unknown arg: $1"; print_help; exit 1;;
  esac
done

timestamp() { date +"%Y%m%d_%H%M%S"; }
LOG="$HOME/topup_batch_$(timestamp).log"
exec > >(tee -a "$LOG") 2>&1

have_cmd() { command -v "$1" >/dev/null 2>&1; }
first_existing() { for p in "$@"; do [[ -f "$p" ]] && { echo "$p"; return 0; }; done; return 1; }
json_of() { local nii="$1"; [[ "$nii" == *.nii.gz ]] && echo "${nii%.nii.gz}.json" || echo "${nii%.nii}.json"; }
stem_of() { local b; b="$(basename "$1")"; [[ "$b" == *.nii.gz ]] && echo "${b%.nii.gz}" || echo "${b%.nii}"; }
nvols() { local img="$1"; have_cmd fslnvols && fslnvols "$img" || fslval "$img" dim4; }

# Build BIDS path that tolerates empty ses
build_path() {
  local root="$1" sub="$2" ses="$3" kind="$4" fname="$5"
  if [[ -z "$ses" ]]; then
    printf "%s/%s/%s/%s\n" "$root" "$sub" "$kind" "$fname"
  else
    printf "%s/%s/%s/%s/%s\n" "$root" "$sub" "$ses" "$kind" "$fname"
  fi
}

bold_for_task() {
  local root="$1" sub="$2" ses="$3" t="$4"
  first_existing \
    "$(build_path "$root" "$sub" "$ses" func "${sub}${ses:+_${ses}}_task-${t}_bold.nii")" \
    "$(build_path "$root" "$sub" "$ses" func "${sub}${ses:+_${ses}}_task-${t}_bold.nii.gz")"
}

# Canonical BIDS fmap: dir-<ap|pa> _task-<task> _epi
fmap_for_task_dir() {
  local root="$1" sub="$2" ses="$3" dir="$4" t="$5"
  first_existing \
    "$(build_path "$root" "$sub" "$ses" fmap "${sub}${ses:+_${ses}}_dir-${dir}_task-${t}_epi.nii")" \
    "$(build_path "$root" "$sub" "$ses" fmap "${sub}${ses:+_${ses}}_dir-${dir}_task-${t}_epi.nii.gz")"
}

# Fallback: scan fmap dir for keywords
scan_fmap_by_keywords() {
  local fmap_dir="$1"; shift
  local -a keys=("$@")
  shopt -s nullglob nocaseglob
  local hits=()
  for ext in nii nii.gz; do
    for f in "$fmap_dir"/*."$ext"; do
      local base="$(basename "$f")"
      for k in "${keys[@]}"; do
        if [[ "$base" == *"$k"* ]]; then
          hits+=("$f"); break
        fi
      done
    done
  done
  shopt -u nullglob nocaseglob
  # choose the shortest name if multiple (heuristic)
  if ((${#hits[@]})); then
    printf "%s\n" "${hits[@]}" | awk '{print length, $0}' | sort -n | cut -d' ' -f2- | head -n1
  else
    return 1
  fi
}

find_topup_config() {
  local c
  for c in "${FSLDIR:-}/etc/flirtsch/b02b0.cnf" "${FSLDIR:-}/etc/b02b0.cnf" \
           "/usr/share/fsl/etc/flirtsch/b02b0.cnf" "/usr/local/fsl/etc/flirtsch/b02b0.cnf"; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

prep_one_blip() {
  local in="$1" out="$2"
  local nv; nv="$(nvols "$in")"
  if [[ -z "$nv" || "$nv" -le 0 ]]; then echo "  ERROR: cannot read nvols for $in"; return 1; fi
  if [[ "$nv" -gt 1 ]]; then
    echo "  $in has $nv vols → mean → $out"
    fslmaths "$in" -Tmean "$out"
  else
    fslchfiletype NIFTI_GZ "$in" "$out"
  fi
}

# We assume j-axis PE; use blipA_1vol to read pixdim2 as SPE (common AP/PA layout)
pe_size_mm() { fslval blipA_1vol.nii.gz pixdim2; }

echo "== FSL check =="
have_cmd fslversion && fslversion || echo "fslversion not found"
echo "FSLDIR=${FSLDIR:-"(unset)"}"
echo "PATH=$PATH"
uname -a
for c in topup applytopup fslmaths fslmerge fslroi fslstats fslhd fslnvols slicer; do
  have_cmd "$c" || echo "WARNING: $c not found in PATH"
done
echo "ROOT=$ROOT"
echo "RUNS=$BOLD_RUNS"
echo "N_WORKERS=$N_WORKERS  TOPUP_NTHR=$TOPUP_NTHR"
echo "AP_KEYS=${AP_KEYS[*]}  PA_KEYS=${PA_KEYS[*]}"
echo

[[ -d "$ROOT" ]] || { echo "ERROR: ROOT not found: $ROOT"; exit 1; }

STATUS_TSV="$ROOT/topup_batch_status_$(timestamp).tsv"
echo -e "STATUS\tsub\tses\trun\tbold\tout" > "$STATUS_TSV"

# -------- core runner for one (sub,ses,run) --------
process_one() {
  local sub="$1" ses="$2" run="$3"

  local bold ap pa fmap_dir
  bold="$(bold_for_task "$ROOT" "$sub" "$ses" "$run")" || {
    echo "SKIP [$sub ${ses:-(nos)} $run] no BOLD"
    echo -e "SKIP\t$sub\t${ses:-}\t$run\t(na)\t(na)" >> "$STATUS_TSV"
    return 0
  }

  # Prefer canonical dir-ap/dir-pa
  ap="$(fmap_for_task_dir "$ROOT" "$sub" "$ses" ap "$run")" || true
  pa="$(fmap_for_task_dir "$ROOT" "$sub" "$ses" pa "$run")" || true

  # Fallback: keyword scan in fmap/
  fmap_dir="$(build_path "$ROOT" "$sub" "$ses" fmap "")"
  fmap_dir="${fmap_dir%/}"  # strip trailing slash from empty fname
  if [[ -z "$ap" && -d "$fmap_dir" ]]; then
    ap="$(scan_fmap_by_keywords "$fmap_dir" "${AP_KEYS[@]}")" || true
  fi
  if [[ -z "$pa" && -d "$fmap_dir" ]]; then
    pa="$(scan_fmap_by_keywords "$fmap_dir" "${PA_KEYS[@]}")" || true
  fi

  local work="$ROOT/topup_work_${sub}_${ses:-nos}"
  mkdir -p "$work"; cd "$work" || {
    echo "ERR cd work"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(workdir)" >> "$STATUS_TSV"; return 1; }

  if (( DRY_RUN )); then
    echo "[DRY] $sub ${ses:-(nos)} $run"
    echo "      BOLD: $bold"
    echo "      AP?: ${ap:-<none>}"
    echo "      PA?: ${pa:-<none>}"
    return 0
  fi

  if [[ -z "$ap" || -z "$pa" ]]; then
    local bold_stem; bold_stem="$(stem_of "$bold")"
    local miss_txt="$work/blipMissing_${bold_stem}.txt"
    {
      echo "Timestamp: $(date -Iseconds)"
      echo "Subject: $sub"
      echo "Session: ${ses:-}"
      echo "Run: $run"
      echo "BOLD: $bold"
      echo
      echo "Missing fmap(s):"
      [[ -z "$ap" ]] && echo "  - AP (or AP-keyword match) is missing"
      [[ -z "$pa" ]] && echo "  - PA (or PA-keyword match) is missing"
      echo
      echo "Searched in: ${fmap_dir:-<no fmap dir>}"
      echo "AP keywords: ${AP_KEYS[*]}"
      echo "PA keywords: ${PA_KEYS[*]}"
    } > "$miss_txt"
    echo "SKIP [$sub ${ses:-(nos)} $run] missing AP/PA fmap → $miss_txt"
    echo -e "SKIP\t$sub\t${ses:-}\t$run\t$bold\t$miss_txt" >> "$STATUS_TSV"
    return 0
  fi

  echo "---- $sub ${ses:-(nos)} $run ----"
  echo "BOLD : $bold"
  echo "BLIPA: $ap"
  echo "BLIPB: $pa"

  local bold_stem summary_txt final_base final_bold
  bold_stem="$(stem_of "$bold")"
  summary_txt="$work/${bold_stem}_blipAnB.txt"
  final_base="${bold_stem}_blipUp_blipDown"
  final_bold="$work/${final_base}.nii.gz"

  # TRT from AP json (fallback 0.050 s)
  local trt ap_json
  trt=""; ap_json="$(json_of "$ap")"
  if [[ -f "$ap_json" ]]; then
    trt="$(grep -Po '"TotalReadoutTime"\s*:\s*\K[0-9.]+(?=[,}])' "$ap_json" || true)"
  fi
  [[ -z "$trt" ]] && { echo "  WARNING: TRT not in JSON; defaulting to 0.050 s"; trt="0.050"; }
  echo "  TRT=${trt}s"

  echo "  -- headers --"
  fslhd "$ap" | egrep 'dim[1234]|pixdim[1234]' | sed 's/^/    AP: /'
  fslhd "$pa" | egrep 'dim[1234]|pixdim[1234]' | sed 's/^/    PA: /'
  fslhd "$bold"| egrep 'dim[1234]|pixdim[1234]' | sed 's/^/  BOLD: /'

  # 1-vol blips + QA before
  prep_one_blip "$ap" blipA_1vol.nii.gz || { echo "  ERROR prepping AP"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(prep AP)" >> "$STATUS_TSV"; return 1; }
  prep_one_blip "$pa" blipB_1vol.nii.gz || { echo "  ERROR prepping PA"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(prep PA)" >> "$STATUS_TSV"; return 1; }
  echo "  blipA vols: $(nvols blipA_1vol.nii.gz)"
  echo "  blipB vols: $(nvols blipB_1vol.nii.gz)"
  fslmaths blipA_1vol.nii.gz -sub blipB_1vol.nii.gz before_diff.nii.gz
  fslmaths before_diff.nii.gz -abs before_diff_abs.nii.gz
  have_cmd slicer && slicer blipA_1vol.nii.gz -u -s 2 -z 0.5 blipA_z.png
  have_cmd slicer && slicer blipB_1vol.nii.gz -u -s 2 -z 0.5 blipB_z.png
  have_cmd slicer && slicer before_diff.nii.gz -u -s 2 -z 0.5 before_diff_z.png

  # acqp (AP = j-, PA = j)
  printf "%s %s\n%s %s\n" "0 -1 0" "$trt" "0  1 0" "$trt" > acqp.txt
  sed -i 's/\r$//' acqp.txt

  # blips 4D
  fslmerge -t blips.nii.gz blipA_1vol.nii.gz blipB_1vol.nii.gz
  [[ "$(nvols blips.nii.gz)" -eq 2 ]] || { echo "  ERROR: blips must be 2 vols"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(blips2)" >> "$STATUS_TSV"; return 1; }

  # TOPUP
  local cfg; cfg="$(find_topup_config || true)"
  if [[ -n "$cfg" ]]; then
    echo "  Using TOPUP config: $cfg  (nthr=$TOPUP_NTHR)"
    topup --imain=blips.nii.gz --datain=acqp.txt --config="$cfg" \
          --nthr="$TOPUP_NTHR" \
          --out=topup_results --fout=field_Hz --iout=unwarped_blips \
          --dfout=warpfield_mm --jacout=jac_det --logout=topup_run.log -v || {
      echo "  WARN: retry TOPUP gentler (--warpres=6 --subsamp=1)"
      topup --imain=blips.nii.gz --datain=acqp.txt \
            --warpres=6 --subsamp=1 --nthr="$TOPUP_NTHR" \
            --out=topup_results --fout=field_Hz --iout=unwarped_blips \
            --dfout=warpfield_mm --jacout=jac_det --logout=topup_run.log -v || {
        echo "  ERROR: TOPUP failed"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(topup)" >> "$STATUS_TSV"; return 1; }
    }
  else
    echo "  No config found; using --warpres=6 --subsamp=1  (nthr=$TOPUP_NTHR)"
    topup --imain=blips.nii.gz --datain=acqp.txt \
          --warpres=6 --subsamp=1 --nthr="$TOPUP_NTHR" \
          --out=topup_results --fout=field_Hz --iout=unwarped_blips \
          --dfout=warpfield_mm --jacout=jac_det --logout=topup_run.log -v || {
      echo "  ERROR: TOPUP failed"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(topup)" >> "$STATUS_TSV"; return 1; }
  fi

  # Field stats + VSM/Jac
  local FIELD_STATS; FIELD_STATS="$(fslstats field_Hz.nii.gz -R -M -S)"
  local SPE VSM_VOX_STATS VSM_MM_STATS
  SPE="$(pe_size_mm)"
  fslmaths field_Hz.nii.gz -mul "$trt" vsm_vox.nii.gz
  fslmaths vsm_vox.nii.gz -abs vsm_vox_abs.nii.gz
  fslmaths vsm_vox.nii.gz -mul "$SPE" vsm_mm.nii.gz
  fslmaths vsm_mm.nii.gz -abs vsm_mm_abs.nii.gz
  VSM_VOX_STATS="$(fslstats vsm_vox_abs.nii.gz -M -P 50 -P 95 -P 99 -R)"
  VSM_MM_STATS="$( fslstats vsm_mm_abs.nii.gz  -M -P 50 -P 95 -P 99 -R)"

  # choose inindex for BOLD
  local inindex=1 bold_json ped
  bold_json="$(json_of "$bold")"
  if [[ -n "$PEDIR_OVERRIDE" ]]; then
    case "$PEDIR_OVERRIDE" in j-) inindex=1;; j) inindex=2;; esac
  elif [[ -f "$bold_json" ]]; then
    ped="$(grep -Po '"PhaseEncodingDirection"\s*:\s*"\K[^"]+' "$bold_json" || true)"
    case "${ped:-}" in j-) inindex=1;; j) inindex=2;; *) inindex=1;; esac
  else
    inindex=1
  fi
  echo "  Using inindex=$inindex"

  # applytopup to BOLD
  applytopup --imain="$bold" --datain=acqp.txt --inindex="$inindex" \
             --topup=topup_results --method=jac --out="$final_base" || {
    echo "  ERROR: applytopup BOLD failed"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(applytopup)" >> "$STATUS_TSV"; return 1; }
  [[ -f "${final_base}.nii.gz" ]] || { echo "  ERROR: missing corrected BOLD"; echo -e "FAIL\t$sub\t${ses:-}\t$run\t$bold\t(no_out)" >> "$STATUS_TSV"; return 1; }

  # QA After |A-B|
  local BEFORE_STATS AFTER_STATS NV_HIFI
  applytopup --imain=blipA_1vol.nii.gz,blipB_1vol.nii.gz \
             --datain=acqp.txt --inindex=1,2 \
             --topup=topup_results --method=jac --out=hifi_b0_pair || true
  if [[ -f hifi_b0_pair.nii.gz ]]; then
    NV_HIFI="$(nvols hifi_b0_pair.nii.gz)"
    if [[ "$NV_HIFI" -ge 2 ]]; then
      fslroi hifi_b0_pair.nii.gz hifi0.nii.gz 0 1
      fslroi hifi_b0_pair.nii.gz hifi1.nii.gz 1 1
      fslmaths hifi0.nii.gz -sub hifi1.nii.gz after_diff.nii.gz
      fslmaths after_diff.nii.gz -abs after_diff_abs.nii.gz
      have_cmd slicer && slicer hifi_b0_pair.nii.gz -u -s 2 -z 0.5 hifi_b0_pair_z.png
      BEFORE_STATS="$(fslstats before_diff_abs.nii.gz -M -P 95 -P 99 -R)"
      AFTER_STATS="$( fslstats after_diff_abs.nii.gz  -M -P 95 -P 99 -R)"
    else
      BEFORE_STATS="$(fslstats before_diff_abs.nii.gz -M -P 95 -P 99 -R)"
      AFTER_STATS="(skipped: ${NV_HIFI} vol)"
    fi
  else
    BEFORE_STATS="$(fslstats before_diff_abs.nii.gz -M -P 95 -P 99 -R)"
    AFTER_STATS="(missing)"
  fi

  # write summary
  {
    echo "BOLD: $bold"
    echo "AP blip: $ap"
    echo "PA blip: $pa"
    echo "TRT (s): $trt"
    echo "Field_Hz stats (min max mean std): $FIELD_STATS"
    echo "VSM_vox abs (mean median P95 P99 min max): $VSM_VOX_STATS"
    echo "VSM_mm  abs (mean median P95 P99 min max):  $VSM_MM_STATS"
    echo "Before |A-B| abs (mean P95 P99 min max):    $BEFORE_STATS"
    echo "After  |A-B| abs (mean P95 P99 min max):    $AFTER_STATS"
    echo "Corrected BOLD: $(readlink -f "${final_base}.nii.gz")"
  } > "$summary_txt"

  # copy outputs next to original BOLD
  local func_dir; func_dir="$(dirname "$bold")"
  cp -f "${final_base}.nii.gz" "$func_dir/"
  cp -f "$summary_txt"        "$func_dir/"

  echo "OK  [$sub ${ses:-} $run] → $(basename "${final_base}.nii.gz")"
  echo -e "OK\t$sub\t${ses:-}\t$run\t$bold\t${final_base}.nii.gz" >> "$STATUS_TSV"
  return 0
}

# ---------- build task list ----------
mapfile -t subs < <(find "$ROOT" -maxdepth 1 -type d -name 'sub-*' | sort)
(( ${#subs[@]} > 0 )) || { echo "ERROR: no sub-* under $ROOT"; exit 1; }

TASKS=()
for sub_path in "${subs[@]}"; do
  sub="$(basename "$sub_path")"
  mapfile -t sess < <(find "$sub_path" -maxdepth 1 -type d -name 'ses-*' | sort)
  if (( ${#sess[@]} == 0 )); then
    for run in $BOLD_RUNS; do
      TASKS+=("$sub||$run")   # empty ses between pipes
    done
  else
    for ses_path in "${sess[@]}"; do
      ses="$(basename "$ses_path")"
      for run in $BOLD_RUNS; do
        TASKS+=("$sub|$ses|$run")
      done
    done
  fi
done

echo "Total tasks: ${#TASKS[@]} (N_WORKERS=$N_WORKERS)  DRY_RUN=$DRY_RUN"
echo

# ---------- run with a simple worker pool ----------
running=0
for task in "${TASKS[@]}"; do
  IFS='|' read -r sub ses run <<<"$task"
  (
    # Normalize empty session token
    [[ "$ses" == "" ]] && ses=""
    process_one "$sub" "$ses" "$run"
  ) &

  ((running++))
  if (( running >= N_WORKERS )); then
    wait -n
    ((running--))
  fi
done

wait

echo
echo "== BATCH SUMMARY (from $STATUS_TSV) =="
ok=$(grep -c $'^OK\t' "$STATUS_TSV" || true)
sk=$(grep -c $'^SKIP\t' "$STATUS_TSV" || true)
fl=$(grep -c $'^FAIL\t' "$STATUS_TSV" || true)
echo "  OK   : ${ok:-0}"
echo "  SKIP : ${sk:-0}"
echo "  FAIL : ${fl:-0}"
echo "Status TSV: $STATUS_TSV"
echo "Master log: $LOG"
