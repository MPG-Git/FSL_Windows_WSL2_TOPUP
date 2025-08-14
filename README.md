# FSL on Windows (WSL2 + Ubuntu) — Install Guide

This guide shows how to install **FSL 6.0.7.18** on Windows using **WSL2** and **Ubuntu 22.04 LTS**, with a fully working `topup` command for distortion correction.

---

## 1Install Ubuntu (WSL2) on Windows

### 1. Enable WSL2 & Virtual Machine Platform
1. **Open PowerShell as Administrator**
   - Press `Start`, type `PowerShell`
   - Right-click → **Run as Administrator**
2. **Enable WSL**:
```powershell
wsl --install
```
3. If you already have WSL and want to ensure version 2:
```powershell
wsl --set-default-version 2
```
4. **Restart your computer** when prompted.

---

### 2. Install Ubuntu from Microsoft Store
1. Open the **Microsoft Store**.
2. Search for **Ubuntu 22.04 LTS** (or newer like 24.04 LTS).
3. Click **Get / Install**.
4. Launch Ubuntu from the **Start menu**.

---

### 3. First-time Ubuntu Setup
- Wait for the "Installing..." message to finish.
- Enter:
  - **Username** (e.g., `matt`) — Linux account name (not your Windows login)
  - **Password** — any password you like; used for software installs inside Ubuntu.

---

### 4. Confirm Ubuntu & WSL Version
Back in **PowerShell** (normal window):
```powershell
wsl -l -v
```
You should see:
```
  NAME            STATE           VERSION
* Ubuntu-22.04    Running         2
```
If `VERSION` is 1:
```powershell
wsl --set-version Ubuntu-22.04 2
```

---

### 5. Access Windows Drives in Ubuntu
Inside Ubuntu:
```bash
cd /mnt/f/UIC_DDP_Data
ls
```
- `/mnt/c/` = C:\
- `/mnt/f/` = F:\

---

## Install FSL via micromamba (conda-forge)

> This avoids the old `fslinstaller.py` issues and gives you the latest maintained conda build of FSL.

### 1. Install dependencies
```bash
sudo apt update
sudo apt install -y bzip2 xz-utils tar curl ca-certificates
```

---

### 2. Download micromamba
```bash
cd ~
wget -O micromamba.tar.bz2 https://micro.mamba.pm/api/micromamba/linux-64/latest
```

---

### 3. Unpack micromamba
```bash
mkdir -p ~/micromamba
tar -xvjf micromamba.tar.bz2 -C ~/micromamba --strip-components=1 bin/micromamba
ls -l ~/micromamba/micromamba  # <-- should show a file
```

---

### 4. Create the FSL environment
```bash
~/micromamba/micromamba create -y -p ~/fsl-env -c conda-forge fsl=6.0.7.18
```

---

### 5. Test before adding to PATH
```bash
~/micromamba/micromamba run -p ~/fsl-env topup -h | head -n 5
```
If you see the TOPUP help banner, the install worked.

---

### 6. Add FSL to your shell permanently
```bash
# Remove any old/bad lines
sed -i '/FSLDIR/d;/fslconf\/fsl\.sh/d;/FSLDIR\/bin/d' ~/.bashrc

# Add correct env vars
cat <<'EOF' >> ~/.bashrc
export FSLDIR=$HOME/fsl-env
. ${FSLDIR}/etc/fslconf/fsl.sh
export PATH=$FSLDIR/bin:$PATH
EOF

# Reload config
source ~/.bashrc
```

---

### 7. Verify final install
```bash
echo $FSLDIR       # should be /home/<user>/fsl-env
which topup        # should be /home/<user>/fsl-env/bin/topup
topup -h | head -n 5
```

---

## Running TOPUP on Your Data (Example)

```bash
# Move to your data folder
cd /mnt/f/UIC_DDP_Data/Doors_data_files/sub-001/ses-amph/fmap

# Merge blip-up and blip-down
fslmerge -t blip_pairs.nii.gz sub-001_ses-amph_dir-ap_task-doors1_epi.nii.gz sub-001_ses-amph_dir-pa_task-doors1_epi.nii.gz

# Create acquisition parameters file (acqparams.txt)
cat <<EOF > acqparams.txt
0 1 0 0.045
0 -1 0 0.045
EOF

# Run TOPUP
topup --imain=blip_pairs.nii.gz --datain=acqparams.txt --config=b02b0.cnf       --out=topup_results --iout=blip_pairs_corrected

# Apply TOPUP to BOLD
applytopup --imain=sub-001_ses-amph_task-doors1_bold.nii.gz            --inindex=1 --datain=acqparams.txt --topup=topup_results            --method=jac --out=doors1_bold_topup.nii.gz
```

---

## Troubleshooting WSL/FSL Install Issues

### **1. `$FSLDIR` points to the wrong location**
**Symptom:**
```bash
echo $FSLDIR
# Shows /usr/share/fsl/... or /home/user/fslsed
which topup
# "no topup in PATH" or points to wrong folder
```
**Fix:**
```bash
sed -i '/FSLDIR/d;/fslconf\/fsl\.sh/d;/FSLDIR\/bin/d' ~/.bashrc
cat <<'EOF' >> ~/.bashrc
export FSLDIR=$HOME/fsl-env
. ${FSLDIR}/etc/fslconf/fsl.sh
export PATH=$FSLDIR/bin:$PATH
EOF
source ~/.bashrc
```

---

### **2. `tar` fails with: "bzip2: command not found"**
**Fix:**
```bash
sudo apt update
sudo apt install -y bzip2 xz-utils tar
```

---

### **3. Old `fslinstaller.py` doesn’t work**
**Fix:** Use micromamba instead:
```bash
~/micromamba/micromamba create -y -p ~/fsl-env -c conda-forge fsl=6.0.7.18
```

---

### **4. `which topup` works, but `topup` errors about missing config**
**Fix:**
```bash
. ${FSLDIR}/etc/fslconf/fsl.sh
```

---

### **5. Forgot your Ubuntu (WSL) password**
**Fix:**
```powershell
wsl -u root
```
Then inside Ubuntu:
```bash
passwd yourusername
```

---

### **6. Checking that `topup` is actually available**
```bash
echo $FSLDIR
which topup
topup -h | head -n 5
```

---

 **Pro tip:** If something still doesn’t work, check the installer log:
```bash
tail -n 60 ~/fsl_installation_*.log 2>/dev/null
```
