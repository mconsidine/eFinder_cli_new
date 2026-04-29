#!/bin/bash
# eFinder first-boot setup. Runs once via efinder-firstboot.service.
# Idempotent in spirit but guarded by /var/lib/efinder/firstboot.done.

set -euo pipefail

LOG() { echo "[firstboot] $*"; }
WARN() { echo "[firstboot] WARNING: $*" >&2; }
FAIL() { echo "[firstboot] ERROR: $*" >&2; exit 1; }

LOG "Starting first-boot configuration"

mkdir -p /var/lib/efinder /etc/efinder

# --- Hardware sanity check ----------------------------------------------------

MODEL_FILE=/proc/device-tree/model
if [ -r "$MODEL_FILE" ]; then
  MODEL=$(tr -d '\0' < "$MODEL_FILE")
  LOG "Detected hardware: $MODEL"
  case "$MODEL" in
    *"Zero 2"*) : ;;
    *"Pi 3"*|*"Pi 4"*|*"Pi 5"*)
      WARN "Unsupported Pi model ($MODEL); some pinning assumptions may be wrong"
      ;;
    *)
      WARN "Unknown hardware ($MODEL); proceeding anyway"
      ;;
  esac
else
  WARN "Could not read $MODEL_FILE"
fi

# --- Camera detection ---------------------------------------------------------

if command -v libcamera-hello >/dev/null 2>&1; then
  if libcamera-hello --list-cameras 2>&1 | grep -q "Available cameras"; then
    LOG "Camera detected (libcamera reports at least one)"
  else
    WARN "No camera detected by libcamera. Check ribbon cable orientation."
    WARN "First-boot continues; camera can be added later."
  fi
else
  WARN "libcamera-hello not installed; cannot verify camera"
fi

# --- Generate per-unit hotspot SSID -------------------------------------------

if ! nmcli -t -f NAME con show | grep -qx "efinder-hotspot"; then
  MAC=$(ip link show wlan0 2>/dev/null | awk '/ether/ {gsub(":",""); print $2; exit}')
  if [ -n "${MAC:-}" ]; then
    SSID="efinder-${MAC: -4}"
  else
    SSID="efinder-$(hostname | tr -dc 'a-z0-9' | head -c 4)"
  fi
  LOG "Creating fallback hotspot connection: SSID=$SSID"
  nmcli con add type wifi ifname wlan0 con-name efinder-hotspot autoconnect no \
    ssid "$SSID" \
    wifi.mode ap \
    wifi.band bg \
    ipv4.method shared \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "efinder12" \
    || WARN "Could not create hotspot connection"
else
  LOG "Hotspot connection already exists"
fi

# --- Tmpfs mounts for image scratch and /var/tmp ------------------------------
# Keep tetra3/cedar-solve database loads off SD wear; small workspace.

if ! grep -q "^tmpfs /var/tmp" /etc/fstab; then
  LOG "Adding /var/tmp tmpfs mount"
  echo "tmpfs /var/tmp tmpfs nodev,nosuid,size=10M 0 0" >> /etc/fstab
fi

mkdir -p /var/lib/efinder/captures
chown -R efinder:efinder /var/lib/efinder

# --- NumPy / BLAS diagnostic --------------------------------------------------
# NumPy's linear algebra perf depends entirely on which BLAS backend it
# links against. OpenBLAS is multi-threaded and SIMD-optimized; the
# reference BLAS is single-threaded and slow. Trixie usually ships with
# OpenBLAS, but we record what's actually linked so we can spot the
# slow case in the logs without having to ssh in and check.
PY=/opt/efinder/venv/bin/python
if [ -x "$PY" ]; then
  BLAS_INFO=$("$PY" -c "
import numpy as np
try:
    info = np.show_config(mode='dicts')
    libs = []
    for sect in ('blas_info', 'blas_opt_info', 'lapack_info', 'lapack_opt_info'):
        d = info.get(sect, {}) or {}
        for lib in d.get('libraries', []) or []:
            libs.append(lib)
    if libs:
        print('NumPy BLAS libs: ' + ', '.join(sorted(set(libs))))
    else:
        print('NumPy BLAS libs: unknown (newer NumPy uses different config layout)')
except Exception as e:
    print(f'NumPy config introspection failed: {e}')
" 2>&1 || echo "could not introspect numpy config")
  LOG "$BLAS_INFO"
  if echo "$BLAS_INFO" | grep -qi "openblas\|blis\|mkl"; then
    LOG "Optimized BLAS detected; NumPy linear algebra should be fast"
  elif echo "$BLAS_INFO" | grep -qi "blas\|lapack"; then
    WARN "NumPy may be using reference BLAS (slow). Consider:"
    WARN "  sudo apt install libopenblas0 && sudo systemctl restart efinder"
  fi
else
  LOG "Skipping NumPy/BLAS diagnostic (venv not yet present)"
fi

# --- vm.swappiness -- minimize SD card wear -----------------------------------

if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
  echo "vm.swappiness = 0" >> /etc/sysctl.conf
fi

# --- Default config file ------------------------------------------------------

if [ ! -f /etc/efinder/efinder.conf ]; then
  LOG "Installing default config"
  cp /opt/efinder/etc/efinder.conf.default /etc/efinder/efinder.conf
  chown efinder:efinder /etc/efinder/efinder.conf
fi

# --- Mark done ----------------------------------------------------------------

date -u +"%Y-%m-%dT%H:%M:%SZ" > /var/lib/efinder/firstboot.done
LOG "First-boot configuration complete"
