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

# --- Avahi: ensure it is running (config was pre-baked at image build) --------
if systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
  systemctl enable --now avahi-daemon.service 2>/dev/null || \
    WARN "Could not enable avahi-daemon"
  systemctl restart avahi-daemon.service 2>/dev/null || true
else
  WARN "avahi-daemon not installed; mDNS efinder.local won't work"
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

mkdir -p /var/lib/efinder/captures
chown -R efinder:efinder /var/lib/efinder

# --- Mark done ----------------------------------------------------------------

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DONE_MARKER"
LOG "First-boot configuration complete"
