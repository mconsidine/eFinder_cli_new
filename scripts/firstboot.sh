#!/bin/bash
# eFinder first-boot setup. Runs once via efinder-firstboot.service.
# Idempotent in spirit but guarded by /var/lib/efinder/firstboot.done.
#
# At the end of first boot the eFinder will be:
#   * Hostname:           efinder.local
#   * USB gadget IP:      10.55.0.1/24 (DHCP server for tethered host)
#   * Wi-Fi AP IP:        10.42.0.1/24 (DHCP server for clients)
#   * Wi-Fi AP SSID:      efinder-XXXX (last 4 of MAC)
#   * Wi-Fi AP password:  12345678 (hardcoded; private-network device)
#   * Wi-Fi station:      not configured (user runs station.sh later)
#
# After first boot, the user can either:
#   1. Tether USB cable to Pi data port -> ssh efinder@10.55.0.1
#      (or ssh efinder@efinder.local once mDNS resolves)
#   2. Connect phone/laptop to the AP SSID -> ssh efinder@10.42.0.1
#      (or ssh efinder@efinder.local once mDNS resolves)
#
# Then run /usr/local/bin/station.sh "MyWiFi" "MyPassword" to switch
# the Wi-Fi from AP mode to joining a real network.

set -euo pipefail

LOG()  { echo "[firstboot] $*"; }
WARN() { echo "[firstboot] WARNING: $*" >&2; }
FAIL() { echo "[firstboot] ERROR: $*" >&2; exit 1; }

DONE_MARKER=/var/lib/efinder/firstboot.done
if [ -f "$DONE_MARKER" ]; then
  LOG "First-boot already completed at $(cat "$DONE_MARKER"); exiting."
  LOG "To force re-run: sudo rm $DONE_MARKER && sudo systemctl start efinder-firstboot"
  exit 0
fi

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

# --- Hostname -----------------------------------------------------------------

CURRENT_HOST=$(hostname)
if [ "$CURRENT_HOST" != "efinder" ]; then
  LOG "Setting hostname: $CURRENT_HOST -> efinder"
  hostnamectl set-hostname efinder
  if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\tefinder/" /etc/hosts
  else
    echo "127.0.1.1	efinder" >> /etc/hosts
  fi
fi

# --- Wi-Fi regulatory country -------------------------------------------------
# wlan0 needs a country code set or many drivers refuse to bring up an AP.
# Default to US; user can change later via raspi-config.

if command -v raspi-config >/dev/null 2>&1; then
  if ! grep -qE '^country=' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
    LOG "Setting Wi-Fi country to US (use raspi-config to change)"
    raspi-config nonint do_wifi_country US 2>/dev/null || \
      WARN "raspi-config do_wifi_country failed; AP may not come up"
  fi
fi

# --- Avahi configuration ------------------------------------------------------
# Avahi by default advertises on every interface, which is what we want
# (USB gadget, Wi-Fi AP, Wi-Fi station). Just make sure it's running and
# the host name matches.

AVAHI_CONF=/etc/avahi/avahi-daemon.conf
if [ -f "$AVAHI_CONF" ]; then
  # Set host-name to 'efinder' so .local resolution works.
  if grep -qE '^#?host-name=' "$AVAHI_CONF"; then
    sed -i 's/^#\?host-name=.*/host-name=efinder/' "$AVAHI_CONF"
  else
    sed -i '/^\[server\]/a host-name=efinder' "$AVAHI_CONF"
  fi
fi

if systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
  systemctl enable --now avahi-daemon.service || \
    WARN "Could not enable avahi-daemon"
  systemctl restart avahi-daemon.service 2>/dev/null || true
else
  WARN "avahi-daemon not installed; mDNS efinder.local won't work"
  WARN "Install with: sudo apt install avahi-daemon"
fi

# --- USB Ethernet gadget profile ---------------------------------------------
# Kernel modules dwc2 + g_ether are loaded via cmdline.txt edits made at
# image build. When the cable is plugged in, the kernel creates usb0.
# This profile tells NetworkManager to give it a static IP and run a DHCP
# server (so the host gets 10.55.0.x). 'ifname usb0' makes the profile
# apply regardless of the random MAC g_ether picks each boot.

if ! nmcli -t -f NAME con show | grep -qx "efinder-usb"; then
  LOG "Creating usb0 NetworkManager profile (10.55.0.1/24)"
  nmcli con add \
    type ethernet \
    ifname usb0 \
    con-name efinder-usb \
    autoconnect yes \
    ipv4.method shared \
    ipv4.addresses 10.55.0.1/24 \
    ipv6.method ignore \
    || WARN "Could not create usb0 profile"
else
  LOG "usb0 profile already exists"
fi

# --- Wi-Fi access point profile ----------------------------------------------

MAC=$(ip link show wlan0 2>/dev/null | awk '/ether/ {gsub(":",""); print $2; exit}')
if [ -n "${MAC:-}" ]; then
  AP_SSID="efinder-${MAC: -4}"
else
  AP_SSID="efinder"
  WARN "Could not read wlan0 MAC; using SSID $AP_SSID"
fi
AP_PASS="12345678"

if ! nmcli -t -f NAME con show | grep -qx "efinder-ap"; then
  LOG "Creating Wi-Fi AP profile: SSID=$AP_SSID password=$AP_PASS"
  nmcli con add \
    type wifi \
    ifname wlan0 \
    con-name efinder-ap \
    autoconnect yes \
    ssid "$AP_SSID" \
    wifi.mode ap \
    wifi.band bg \
    ipv4.method shared \
    ipv4.addresses 10.42.0.1/24 \
    ipv6.method ignore \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$AP_PASS" \
    || WARN "Could not create AP profile"

  LOG "============================================="
  LOG "  AP SSID:     $AP_SSID"
  LOG "  AP password: $AP_PASS"
  LOG "  AP IP:       10.42.0.1"
  LOG "  Hostname:    efinder.local"
  LOG "============================================="
else
  LOG "AP profile already exists"
fi

# --- Bring connections up now -------------------------------------------------

if ip link show usb0 >/dev/null 2>&1; then
  nmcli con up efinder-usb >/dev/null 2>&1 \
    || WARN "Could not activate efinder-usb (may auto-connect later)"
fi

if nmcli -t -f DEVICE,STATE dev | grep -q "^wlan0:disconnected"; then
  LOG "Activating Wi-Fi AP"
  nmcli con up efinder-ap >/dev/null 2>&1 \
    || WARN "Could not bring up AP (it'll auto-connect at next boot)"
fi

# --- Tmpfs for /var/tmp -------------------------------------------------------

if ! grep -q "^tmpfs /var/tmp" /etc/fstab; then
  LOG "Adding /var/tmp tmpfs mount"
  echo "tmpfs /var/tmp tmpfs nodev,nosuid,size=10M 0 0" >> /etc/fstab
fi

mkdir -p /var/lib/efinder/captures
chown -R efinder:efinder /var/lib/efinder

# --- NumPy / BLAS diagnostic --------------------------------------------------

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

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DONE_MARKER"
LOG "First-boot configuration complete"
