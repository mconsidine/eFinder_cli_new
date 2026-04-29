# eFinder (Pi Zero 2W edition)

Plate-solving electronic finder for amateur telescopes. Aimed at a
specific hardware target: Raspberry Pi Zero 2W + Arducam 12MP IMX477.
Reports pointing to SkySafari (or any LX200-speaking client) over Wi-Fi.

## Architecture

Three pinned worker processes plus a gRPC microservice on the same Pi:

```
CPU 0 : kernel, IRQs, sshd, journald  (left alone)
CPU 1 : comms_proc       (LX200 TCP server :4060)
CPU 2 : camera_proc      (picamera2 capture loop)
CPU 3 : solver_proc + cedar-detect-server
```

Frame handoff between camera and solver is via a triple-buffered
`multiprocessing.shared_memory` region. Three buffers ensures the camera
never blocks on the solver and the solver always sees the freshest
available frame. The lock is held only for the microseconds needed to
flip ownership integers; the 730 KB frame copy itself is lock-free.

The plate solver is `cedar-solve` (a fork of ESA's `tetra3` with
significant performance improvements -- it still imports as `tetra3`).
Centroid extraction is `cedar-detect`, a Rust gRPC server.

**Zero-copy frame handoff to cedar-detect**: cedar-detect's proto
defines an optional `shmem_name` field on the Image message that lets
the server `shm_open()` the image directly rather than receive 730 KB
of bytes over gRPC. The eFinder solver uses this mode -- it tells
cedar-detect "the frame is at `efinder_frame_<N>` in /dev/shm" and the
server reads it directly. This requires that cedar-detect-server run
as the same user as the eFinder process (both run as `efinder`); the
systemd units are configured accordingly.

## Layout

```
efinder/                Python application (the launcher + workers)
systemd/                Three unit files
scripts/install.sh      Idempotent installer; runs in two modes
scripts/firstboot.sh    One-shot first-boot setup
scripts/efinder-update  In-place updater
build/build-image.sh    Chroot-based Pi image builder
.github/workflows/      CI: build cedar-detect binary + Pi image
```

## How users get it

1. Download the latest `efinder-vX.Y.Z.img.xz` from GitHub releases.
2. Flash to an SD card with `dd`, balena Etcher, or Pi Imager. No
   special configuration needed in Pi Imager -- the eFinder image
   sets up its own network on first boot.
3. Boot. First-boot service runs (~30-60s on first power-on); the Pi
   creates a Wi-Fi access point and a USB Ethernet gadget.
4. Reach the Pi by either:
    * **USB cable:** plug from your computer into the Pi's middle
      micro-USB port (the data port, not the leftmost power port).
      Your computer sees a new Ethernet interface come up; ssh to
      `efinder@10.55.0.1` or `efinder@efinder.local` with password
      `12345678`.
    * **Wi-Fi AP:** look for an SSID like `efinder-XXXX` on your
      phone or laptop. Connect with WPA2 password `12345678`.
      Once connected, ssh to `efinder@10.42.0.1` or
      `efinder@efinder.local` with password `12345678`.

   These are deliberately weak credentials; the device operates on
   private networks only and is not exposed to the public internet.

5. Optional: switch the Pi from AP mode to joining your home Wi-Fi:
   ```
   sudo /usr/local/bin/station.sh "MySSID" "MyPassword"
   ```
   To switch back to AP mode later: `sudo /usr/local/bin/ap.sh`.
6. Connect SkySafari to `efinder.local:4060` (LX200 protocol).
   Works on either AP, station, or upstream Wi-Fi.

### A note on `efinder.local` resolution

mDNS (`.local`) resolution depends on the client OS:
- **Linux, macOS, iOS** -- works out of the box.
- **Windows** -- requires Bonjour Service installed (comes with iTunes
  or many printer drivers), or use the IP address directly.
- **Android** -- system-wide `.local` resolution is unreliable, but
  most SSH apps (Termux, JuiceSSH) handle it. If `.local` doesn't
  resolve in your app, use `10.42.0.1` (AP mode) or `10.55.0.1` (USB
  tether) directly.

For SSH-comfortable users on a fresh Trixie Lite SD card, `bash
scripts/install.sh` works as an alternative to flashing the prebuilt image.

## Build pipeline

* On every push, `build-cedar-detect.yml` cross-compiles
  `cedar-detect-server` for `aarch64-unknown-linux-gnu` and uploads it
  as a workflow artifact.
* On a tagged release, `build-cedar-detect.yml` also attaches the
  binary to the release.
* Then `build-image.yml` runs: downloads the official Trixie Lite image,
  grows it, chroots in via `qemu-aarch64-static`, runs `install.sh` in
  chroot mode (which pulls the cedar-detect-server we just built),
  repacks, and attaches `.img.xz` to the release.

For local development on the Dell Precision: install `cross`, then
`cross build --release --target aarch64-unknown-linux-gnu` from the
cedar-detect submodule. Rsync the binary to the Pi and `systemctl
restart cedar-detect.service`.

## Updates after install

```
sudo /usr/local/bin/efinder-update            # latest tag
sudo /usr/local/bin/efinder-update v0.7.1     # specific tag
```

Refuses to update if the working tree has local modifications.

## Things known to need verification

The build pipeline has been carefully designed and statically checked
(`bash build/check-tree.sh` passes), but it has not yet been run
end-to-end. Items that will need checking on first CI run:

1. **cedar-detect submodule must be added.** The `release.yml`
   workflow expects a submodule at `cedar-detect/`. Add it once with:
   ```
   git submodule add https://github.com/smroid/cedar-detect cedar-detect
   git commit -m "vendor cedar-detect"
   ```
   `release.yml` has a precondition check that fails fast with this
   instruction if the submodule is missing.

2. **picamera2 format string for the Arducam 12MP**: `camera_proc.py`
   uses `"YUV420"` and slices the Y plane. Confirmed correct per
   project context.

3. **Trixie Lite base image URL**: `build-image.sh` uses
   `raspios_lite_arm64_latest`. Acceptable per project preference.

4. **cedar-detect server's shmem_name support requires it run as the
   same user as efinder** (so it can `shm_open()` the file). The systemd
   units are configured for this (both run as `efinder`).

5. **Pi OS package availability**: install.sh `apt install`s
   `python3-picamera2` and `python3-libcamera`, which are present on
   Raspberry Pi OS Trixie Lite but not stock Debian Trixie. The
   Trixie Lite image used by build-image.sh is the right base for
   this; just noting in case you ever swap to a different base.

## First-build checklist

When you tag your first release, expect to debug at least one or two
of these (they're the most likely to surface):

- The `cedar-detect-server` bin name in cedar-detect's `Cargo.toml`.
  Currently confirmed via repo README; if cedar-detect upstream
  changes the bin name, the workflow's strip step will fail loudly.
- Image-build CI runtime. Estimated 30-60 minutes; may need
  `timeout-minutes:` bump in `release.yml`.
- Final image size. We grow by 2 GB; if apt installs more than expected
  (especially `apache2`-equivalents pulled in transitively), bump.
- Any pip install that needs to compile (e.g., `grpcio` building from
  source if no aarch64 wheel is published for the Python version on
  Trixie). The chroot has the toolchain (`build-essential`) so this
  works but is slow.

Run `bash build/check-tree.sh` from the repo root before pushing to
catch most issues without burning a CI run.

## Things deferred

* Captive-portal Wi-Fi fallback (if user's Wi-Fi credentials are wrong).
  For now, re-flash to recover. Add `comitup` or `RaspAP` later.
* Lens distortion calibration. cedar-server does this; we don't yet.
* Polar alignment helper. cedar-server does this; we don't yet.
* Adaptive frame rate based on dwell detection.
* Web UI for status / config / update button.
