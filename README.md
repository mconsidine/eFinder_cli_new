# eFinder (Pi Zero 2W edition)

Plate-solving electronic finder for amateur telescopes. Runs on a
Raspberry Pi Zero 2W with an Arducam 12 MP IMX477. Reports pointing
to SkySafari (or any LX200-speaking app) over Wi-Fi or USB tether.

## What it does

- Continuously captures frames and plate-solves them (~1.8 s per solve
  on the Zero 2W at 960×760).
- Serves RA/Dec to SkySafari via LX200 protocol on TCP port 4060.
- Accepts SkySafari's sync command (`:CM#`) to calibrate the boresight
  offset in pixel coordinates, persisted across restarts.
- Self-calibrates field-of-view after ~30 successful solves; tightens
  the FOV tolerance window once calibrated for faster, more robust
  matching.
- Three-point polar alignment helper: rotate the mount in RA only,
  capture three solved positions, decompose the RA-axis offset into
  azimuth and altitude error (requires observer latitude, supplied
  automatically by SkySafari's `:St` command or manually via
  `efinder-ctl polar set-latitude`).
- Web UI on port 80: dashboard with live pointing, polar alignment
  workflow, configuration viewer, live log tail, and one-click update.
- Maintenance CLI (`efinder-ctl`) for boresight, calibration,
  exposure, and polar alignment control without needing the web UI.

## Architecture

Three pinned worker processes plus a gRPC microservice:

```
CPU 0 : kernel, IRQs, sshd, journald  (left alone)
CPU 1 : comms_proc    LX200 TCP :4060, maintenance Unix socket
CPU 2 : camera_proc   picamera2 capture loop
CPU 3 : solver_proc   cedar-solve/tetra3 + cedar-detect gRPC client
        cedar-detect  Rust star-centroid server (same CPU, same user)
```

Frame handoff between camera and solver is via a triple-buffered
`multiprocessing.shared_memory` region (`FrameSlots`). Three buffers
ensure the camera never blocks on the solver; the solver always sees
the freshest available frame. The lock is held only for the
microseconds needed to flip ownership integers; the 730 KB frame copy
is lock-free.

Cedar-detect accesses frames via `shm_open()` directly (using the
optional `shmem_name` field in the gRPC proto), avoiding a 730 KB
gRPC payload on every call. Both processes run as user `efinder` so
the shared-memory file descriptor is accessible.

The plate solver is cedar-solve (a fork of ESA's tetra3 with
significant performance improvements; it still imports as `tetra3`).
Centroid extraction is cedar-detect, a separate Rust gRPC server.

## Repository layout

```
efinder/                Python application (launcher + workers)
  efinder_main.py       Process launcher, signal handling
  camera_proc.py        picamera2 capture loop
  solver_proc.py        cedar-solve/tetra3 solve loop
  comms_proc.py         LX200 server + maintenance socket
  align.py              Boresight alignment state machine
  calibration.py        FOV self-calibration accumulator
  polar.py              Polar alignment math
  polar_run.py          Polar alignment state machine (in solver_proc)
  frame_slots.py        Triple-buffer shared memory
  config.py             Configuration loader / saver
  maint.py              Maintenance socket client library
  worker_cmds.py        Queue command types for inter-process control
webui/                  Flask web UI (port 80)
systemd/                Four unit files
  efinder.service
  cedar-detect.service
  efinder-firstboot.service
  efinder-webui.service
scripts/
  install.sh            Idempotent installer (image-build + bare-metal)
  firstboot.sh          One-shot network setup (runs once via systemd)
  efinder-update        In-place updater
  efinder-ctl           Maintenance CLI
  station.sh            Switch Wi-Fi from AP mode to station mode
  ap.sh                 Switch Wi-Fi back to AP mode
build/
  build-image.sh        QEMU chroot-based Pi image builder
  check-tree.sh         Pre-push static sanity checker
.github/workflows/
  release.yml           Chains cedar-detect build → SD image build
  build-cedar-detect.yml  Standalone cedar-detect build on push to main
proto/
  cedar_detect.proto    gRPC interface to cedar-detect-server
etc/
  efinder.conf.default  Annotated default configuration
```

## Getting it

### Flash the pre-built image (recommended)

1. Download `efinder-vX.Y.Z.img.xz` from GitHub Releases.
2. Flash to an SD card with `dd`, balena Etcher, or Pi Imager. No
   additional configuration is needed — the image sets up its own
   network on first boot.
3. Boot. The first-boot service runs once (~30–60 s) and then the
   eFinder application starts automatically.

### Install on an existing Pi OS Trixie Lite SD card

```bash
sudo bash scripts/install.sh
```

Idempotent; safe to re-run. Requires internet access for `apt` and
`pip`. After install, first-boot runs on the next systemd boot (or
`sudo systemctl start efinder-firstboot` to run it now).

## Connecting after first boot

Two network interfaces come up automatically:

| Interface | Address | How to reach it |
|---|---|---|
| USB Ethernet gadget | `10.55.0.1` | Plug Pi's middle micro-USB (data) port into your computer |
| Wi-Fi access point | `10.42.0.1` | Connect to SSID `efinder-XXXX` (last 4 digits of MAC) |

Default password for both SSH and the Wi-Fi AP: `12345678`.

SSH: `ssh efinder@10.55.0.1` or `ssh efinder@efinder.local`

These are deliberately weak credentials; the device operates on
private networks only and is not exposed to the public internet.

### Switch to station (home Wi-Fi) mode

```bash
sudo /usr/local/bin/station.sh "MySSID" "MyPassword"
```

To switch back to AP mode: `sudo /usr/local/bin/ap.sh`

### mDNS (`.local`) resolution

`efinder.local` is broadcast by avahi-daemon and works on Linux,
macOS, and iOS out of the box. Windows requires Bonjour (comes with
iTunes or many printer drivers); use the IP address directly if not
available. Android `.local` resolution varies by app.

## Using with SkySafari

1. In SkySafari → Settings → Telescope → Setup:
   - Connection: WiFi (TCP)
   - Mount type: Alt-Az, GoTo (or your actual mount type)
   - IP Address: `efinder.local` or `10.42.0.1` / `10.55.0.1`
   - Port: `4060`
   - Scope type: Meade LX-200 GPS

2. Tap **Connect**. SkySafari will start receiving RA/Dec updates.

3. To calibrate the boresight: centre a known star, tap the star in
   SkySafari, then tap **Sync**. The eFinder records the offset from
   the image centre and applies it to all subsequent pointing reports.

## Web UI

Browse to `http://efinder.local` (or the IP address) from any device
on the same network.

| Page | What it does |
|---|---|
| `/` | Live RA/Dec, solve quality, calibration status, exposure control |
| `/polar` | Step-by-step polar alignment workflow |
| `/config` | Read-only view of `/etc/efinder/efinder.conf` |
| `/logs` | Live tail of journalctl for efinder + cedar-detect |
| `/update` | Trigger `efinder-update` in one click |

## Maintenance CLI (`efinder-ctl`)

```bash
efinder-ctl status                      # current solution + boresight
efinder-ctl boresight show              # pixel coordinates of boresight
efinder-ctl boresight center            # reset boresight to frame centre
efinder-ctl boresight set Y X           # set boresight to pixel (Y, X)
efinder-ctl calibration status          # FOV calibration state
efinder-ctl calibration reset           # discard FOV calibration
efinder-ctl exposure get                # current exposure setting
efinder-ctl exposure set 0.3            # change exposure (this session)
efinder-ctl exposure set 0.3 --persist  # change and write to config
efinder-ctl gain set 15.0 --persist
efinder-ctl polar start                 # begin polar alignment capture
efinder-ctl polar status                # capture progress + result
efinder-ctl polar cancel
efinder-ctl polar set-latitude 44.5     # manual latitude override
efinder-ctl version
efinder-ctl ping
```

## Configuration

`/etc/efinder/efinder.conf` — key:value pairs with `#` comments.
Restart required after manual edits (`sudo systemctl restart efinder`).
Any key can be overridden without editing the file:

```bash
EFINDER_EXPOSURE_S=0.5 systemctl restart efinder
```

Key settings and their defaults:

| Key | Default | Notes |
|---|---|---|
| `frame_width` / `frame_height` | 960 / 760 | Camera ROI |
| `exposure_s` | 0.2 | Starting exposure; tunable live |
| `gain` | 20.0 | |
| `fov_deg` | 13.5 | Self-calibrates after ~30 solves |
| `detect_sigma` | 8.0 | Star detection threshold |
| `solve_timeout_ms` | 1500 | Per-frame solver budget |
| `lx200_port` | 4060 | TCP port for SkySafari |
| `boresight_y` / `boresight_x` | 380 / 480 | Pixel offset; set by sync |
| `save_failed_frames` | false | Write failed frames to `/var/lib/efinder/captures/` |

## Updating

```bash
sudo /usr/local/bin/efinder-update              # latest tagged release
sudo /usr/local/bin/efinder-update v0.7.1       # specific version
```

Fetches the new application code, refreshes Python dependencies,
regenerates gRPC stubs, downloads the matching `cedar-detect-server`
binary, and restarts both services. Refuses to update if the working
tree has local modifications.

## Build pipeline

`release.yml` chains two jobs:

1. **cedar-detect**: Cross-compiles `cedar-detect-server` for
   `aarch64-unknown-linux-gnu` with `-C target-cpu=cortex-a53` (5–10%
   speedup over generic aarch64 on the Zero 2W's Cortex-A53). Uploads
   as a workflow artifact and, on tagged releases, attaches to the
   release.

2. **image** (tagged releases and manual dispatch with `build_image=true`):
   Downloads the official Raspberry Pi OS Trixie Lite image, expands
   it, chroots in via `qemu-user-static`, runs `install.sh` in chroot
   mode (which installs the cedar-detect binary from the previous job
   rather than from a release URL), repacks, and attaches
   `efinder.img.xz` to the release.

`build-cedar-detect.yml` runs a standalone cedar-detect build on every
push to `main` (cedar-detect paths) so development artifacts are always
available without triggering a full image build.

For local cross-compilation of cedar-detect (not normally needed —
CI builds and attaches the binary automatically): populate the
submodule, install `cross`, then build:
```bash
git submodule update --init --recursive
cd cedar-detect
cross build --release --target aarch64-unknown-linux-gnu
```
Rsync the resulting binary to the Pi and
`sudo systemctl restart cedar-detect.service`.

## Known limitations and deferred work

### Not yet implemented

- **Dark frame / hot pixel calibration**: infrastructure exists in
  the maintenance socket; camera-side capture and per-frame subtraction
  are not yet written. Cedar-detect's per-frame hot pixel detection
  works without it.

- **Captive portal for wrong Wi-Fi credentials**: if `station.sh` is
  given bad credentials and the Pi can't join the network, the only
  recovery is re-flashing or USB tether. A `comitup`-based captive
  portal is the planned fix.

- **Frame save for diagnostics**: `save_failed_frames: true` in config
  is wired up in the config but the write logic in `solver_proc.py` is
  not yet implemented.

- **No watchdog beyond systemd**: if the solver hangs without crashing,
  systemd won't restart it. A heartbeat check on
  `latest_solution.epoch_monotonic` is the intended fix.

### Limitations to be aware of

- No authentication on the LX200 server or web UI. Anyone on the same
  Wi-Fi segment can connect. Acceptable for a private network; do not
  expose the eFinder to the internet.

- `detect_sigma` and `solve_timeout_ms` defaults are based on limited
  field testing. Once real-sky data accumulates, tune from the median
  solve time and miss rate shown on the dashboard.

- Polar alignment requires ≥ 3 successful plate solves per capture
  point. In poor sky conditions (< 8 detected centroids), the capture
  stalls until the sky clears or exposure is increased.

### First-CI checklist

The build pipeline has been statically verified (`bash build/check-tree.sh`)
but not yet run end-to-end. Likely items to debug on first CI run:

- **cedar-detect submodule**: the submodule is already registered in
  `.gitmodules`. CI checks it out automatically via
  `actions/checkout@v4` with `submodules: recursive` — no manual step
  needed. The workflow has a pre-flight check that will fail fast if
  the submodule were ever removed.

- **Image build timeout**: estimated 30–60 minutes. Bump
  `timeout-minutes:` in `release.yml` if the image job times out.

- **Image partition size**: the build grows the image by 2 GB. If apt
  installs more than expected, bump the resize value in
  `build/build-image.sh`.

- **pip compile time in chroot**: `grpcio` and other packages may
  build from source if no aarch64 wheel exists for the Python version
  on Trixie. The chroot has `build-essential` so this works but adds
  time.
