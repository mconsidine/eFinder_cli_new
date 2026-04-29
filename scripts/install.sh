#!/bin/bash
# eFinder install script.
#
# Two execution modes, autodetected:
#
#   * "fresh"  : run by a user on a freshly flashed Trixie Lite SD card.
#                Does the works: apt update, raspi-config, /boot edits,
#                creates user, then reboots.
#
#   * "chroot" : run inside qemu-aarch64 chroot during image build.
#                Skips raspi-config and reboot. Source tree is staged
#                at /tmp/efinder-src/ by build-image.sh. EFINDER_CHROOT=1.
#
# In chroot mode, an optional EFINDER_CEDAR_DETECT_BIN_LOCAL points to
# a pre-built cedar-detect-server binary; if set we skip the release-URL
# download entirely (used during CI where the release isn't populated
# until both jobs finish).
#
# Idempotent: re-running on a working install should be a no-op except
# for re-pulling the cedar-detect binary if a newer release is found.

set -euo pipefail

# --- Config -------------------------------------------------------------------
EFINDER_USER="efinder"
EFINDER_HOME="/home/${EFINDER_USER}"
EFINDER_DIR="/opt/efinder"
REPO_URL="https://github.com/mconsidine/eFinder_cli.git"
CEDAR_DETECT_REPO="mconsidine/eFinder_cli"
CEDAR_DETECT_BIN="cedar-detect-server"
TARGET_VERSION="${EFINDER_VERSION:-latest}"
IN_CHROOT="${EFINDER_CHROOT:-0}"
LOCAL_CD_BIN="${EFINDER_CEDAR_DETECT_BIN_LOCAL:-}"
SRC_STAGED="/tmp/efinder-src"

LOG()  { echo "==> $*"; }
WARN() { echo "WARNING: $*" >&2; }
FAIL() { echo "ERROR: $*" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------

[ "$EUID" -eq 0 ] || FAIL "Run as root (sudo bash $0)"

if [ "$IN_CHROOT" = "1" ]; then
  LOG "Running in chroot mode (image build) version=$TARGET_VERSION"
  [ -d "$SRC_STAGED" ] \
    || FAIL "chroot mode requires source staged at $SRC_STAGED"
  [ -f "$SRC_STAGED/scripts/install.sh" ] \
    || FAIL "$SRC_STAGED looks incomplete (missing scripts/install.sh)"
  [ -f "$SRC_STAGED/proto/cedar_detect.proto" ] \
    || FAIL "vendored proto missing at $SRC_STAGED/proto/cedar_detect.proto"
else
  LOG "Running in fresh-install mode version=$TARGET_VERSION"
fi

# --- Create efinder user ------------------------------------------------------

if ! id -u "$EFINDER_USER" >/dev/null 2>&1; then
  LOG "Creating user $EFINDER_USER"
  useradd -m -s /bin/bash "$EFINDER_USER"
  usermod -aG video,gpio,i2c,dialout "$EFINDER_USER" || true
fi

# --- System packages ----------------------------------------------------------

LOG "Updating apt and installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip python3-dev \
  python3-numpy python3-picamera2 python3-libcamera \
  build-essential pkg-config \
  curl ca-certificates git \
  protobuf-compiler

# --- Application code ---------------------------------------------------------

if [ "$IN_CHROOT" = "1" ]; then
  # Image-build path: copy staged source into /opt/efinder.
  if [ ! -d "$EFINDER_DIR" ]; then
    LOG "Copying staged source $SRC_STAGED -> $EFINDER_DIR"
    mkdir -p "$EFINDER_DIR"
    # Copy everything except the staged binary (handled separately below).
    cp -r "$SRC_STAGED/." "$EFINDER_DIR/"
    rm -f "$EFINDER_DIR/cedar-detect-server.aarch64"
    chown -R "$EFINDER_USER:$EFINDER_USER" "$EFINDER_DIR"
  else
    WARN "$EFINDER_DIR already exists; reusing"
  fi
else
  # Fresh-install path: clone from GitHub.
  if [ ! -d "$EFINDER_DIR/.git" ]; then
    LOG "Cloning eFinder code to $EFINDER_DIR"
    git clone --depth 1 "$REPO_URL" "$EFINDER_DIR"
    chown -R "$EFINDER_USER:$EFINDER_USER" "$EFINDER_DIR"
  fi
  cd "$EFINDER_DIR"
  if [ "$TARGET_VERSION" != "latest" ]; then
    LOG "Checking out $TARGET_VERSION"
    sudo -u "$EFINDER_USER" git fetch --tags origin
    sudo -u "$EFINDER_USER" git checkout --quiet "$TARGET_VERSION"
  fi
fi

# --- Python venv --------------------------------------------------------------

if [ ! -d "$EFINDER_DIR/venv" ]; then
  LOG "Creating Python venv (with system site packages for picamera2)"
  sudo -u "$EFINDER_USER" python3 -m venv \
    --system-site-packages "$EFINDER_DIR/venv"
fi

LOG "Installing Python deps"
sudo -u "$EFINDER_USER" "$EFINDER_DIR/venv/bin/pip" install --upgrade pip \
  || FAIL "pip install --upgrade pip failed"
sudo -u "$EFINDER_USER" "$EFINDER_DIR/venv/bin/pip" install \
  -r "$EFINDER_DIR/requirements.txt" \
  || FAIL "pip install requirements.txt failed"

# --- Install cedar-detect-server -----------------------------------

if [ -n "$LOCAL_CD_BIN" ]; then
  # Image build with locally-staged binary -- no network fetch.
  [ -f "$LOCAL_CD_BIN" ] || FAIL "EFINDER_CEDAR_DETECT_BIN_LOCAL=$LOCAL_CD_BIN not found"
  LOG "Installing locally-staged $CEDAR_DETECT_BIN"
  install -m 755 "$LOCAL_CD_BIN" /usr/local/bin/${CEDAR_DETECT_BIN}
else
  LOG "Fetching $CEDAR_DETECT_BIN binary"
  if [ "$TARGET_VERSION" = "latest" ]; then
    URL=$(curl -fsSL "https://api.github.com/repos/${CEDAR_DETECT_REPO}/releases/latest" \
          | grep "browser_download_url" \
          | grep "${CEDAR_DETECT_BIN}" \
          | head -n1 \
          | cut -d'"' -f4 || true)
    [ -n "$URL" ] || FAIL "Could not resolve latest $CEDAR_DETECT_BIN URL from $CEDAR_DETECT_REPO"
  else
    URL="https://github.com/${CEDAR_DETECT_REPO}/releases/download/${TARGET_VERSION}/${CEDAR_DETECT_BIN}"
  fi
  LOG "Downloading from $URL"
  TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
  curl -fsSL --retry 3 "$URL" -o "$TMP" \
    || FAIL "Failed to download $CEDAR_DETECT_BIN from $URL"
  install -m 755 "$TMP" /usr/local/bin/${CEDAR_DETECT_BIN}
  trap - EXIT
fi

# --- Generate Python protobuf stubs ------------------------------------------

LOG "Generating Python gRPC stubs from vendored cedar_detect.proto"
[ -f "$EFINDER_DIR/proto/cedar_detect.proto" ] \
  || FAIL "missing $EFINDER_DIR/proto/cedar_detect.proto"
sudo -u "$EFINDER_USER" "$EFINDER_DIR/venv/bin/pip" install --quiet \
  grpcio grpcio-tools \
  || FAIL "pip install grpcio grpcio-tools failed"
sudo -u "$EFINDER_USER" "$EFINDER_DIR/venv/bin/python" \
  -m grpc_tools.protoc \
  -I "$EFINDER_DIR/proto" \
  --python_out="$EFINDER_DIR/proto" \
  --grpc_python_out="$EFINDER_DIR/proto" \
  "$EFINDER_DIR/proto/cedar_detect.proto" \
  || FAIL "protoc compile failed"

# Verify the stubs were actually produced -- protoc sometimes silently
# does nothing if invoked wrong.
[ -f "$EFINDER_DIR/proto/cedar_detect_pb2.py" ] \
  || FAIL "cedar_detect_pb2.py not produced; check protoc invocation"
[ -f "$EFINDER_DIR/proto/cedar_detect_pb2_grpc.py" ] \
  || FAIL "cedar_detect_pb2_grpc.py not produced"

# --- systemd units ------------------------------------------------------------

LOG "Installing systemd units"
install -m 644 "$EFINDER_DIR/systemd/cedar-detect.service"      /etc/systemd/system/
install -m 644 "$EFINDER_DIR/systemd/efinder.service"           /etc/systemd/system/
install -m 644 "$EFINDER_DIR/systemd/efinder-firstboot.service" /etc/systemd/system/
install -m 644 "$EFINDER_DIR/systemd/efinder-webui.service"     /etc/systemd/system/

# Sudoers rule scoped to just efinder-update (used by the web UI)
install -m 440 "$EFINDER_DIR/etc/sudoers.d/efinder-update" /etc/sudoers.d/efinder-update

install -m 755 "$EFINDER_DIR/scripts/efinder-update" /usr/local/bin/
install -m 755 "$EFINDER_DIR/scripts/efinder-ctl"    /usr/local/bin/
install -m 755 "$EFINDER_DIR/scripts/firstboot.sh"   "$EFINDER_DIR/scripts/firstboot.sh"

mkdir -p /etc/efinder /var/lib/efinder
chown -R "$EFINDER_USER:$EFINDER_USER" /var/lib/efinder

if [ ! -f /etc/efinder/efinder.conf ]; then
  install -m 644 -o "$EFINDER_USER" -g "$EFINDER_USER" \
    "$EFINDER_DIR/etc/efinder.conf.default" /etc/efinder/efinder.conf
fi

# --- Web UI -----------------------------------------------------------------
# The Flask app at /opt/efinder/webui is started by efinder-webui.service
# and reads its templates/static assets in place. Nothing more to do.

# --- Boot config / kernel options --------------------------------------------

CONFIG_TXT=/boot/firmware/config.txt
if [ -f "$CONFIG_TXT" ]; then
  if ! grep -q "^camera_auto_detect=1" "$CONFIG_TXT"; then
    LOG "Enabling camera_auto_detect in $CONFIG_TXT"
    echo "camera_auto_detect=1" >> "$CONFIG_TXT"
  fi
  if ! grep -q "^enable_uart=1" "$CONFIG_TXT"; then
    echo "enable_uart=1" >> "$CONFIG_TXT"
  fi
fi

# --- Enable services ---------------------------------------------------------

LOG "Enabling services"
systemctl daemon-reload
systemctl enable cedar-detect.service efinder.service \
                 efinder-firstboot.service efinder-webui.service

if [ "$IN_CHROOT" != "1" ]; then
  LOG "Starting services"
  systemctl start cedar-detect.service efinder.service \
                  efinder-webui.service || true
fi

# --- Reboot if running on real hardware --------------------------------------

if [ "$IN_CHROOT" != "1" ]; then
  LOG "Install complete. Rebooting in 5s..."
  sleep 5
  reboot
else
  LOG "Install complete (chroot mode; image will boot on first power-up)"
fi
