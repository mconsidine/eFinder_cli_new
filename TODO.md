# eFinder TODO

Living document. Update as features land or get deferred.

## Major features (deferred)

### Polar alignment helper
✅ DONE. Three-point algorithm: user rotates mount in RA only, eFinder
captures three plate-solved positions (with dwell detection), fits a
plane through the points on the celestial sphere, the plane's normal
is the apparent RA axis. Decomposes the offset from the true pole
into azimuth and altitude errors using the observer's latitude.

The code is in `efinder/polar.py` (math) and `efinder/polar_run.py`
(state machine, lives in solver process). Maintenance commands:
- `efinder-ctl polar start`           begin a session
- `efinder-ctl polar status`          where are we, what's the user need to do
- `efinder-ctl polar cancel`          abort
- `efinder-ctl polar set-latitude N`  manually set latitude

Latitude flows in automatically from SkySafari's LX200 `:St` command;
manual `set-latitude` is the fallback. If a user starts polar alignment
before SkySafari connects, the capture proceeds normally and the
result is computed-but-undecomposed; once latitude arrives (via
SkySafari or manually), the prior result is retroactively decomposed
into az/alt without requiring a recapture.

Could improve later if needed:
- Capture more than 3 points for noise reduction (already supported
  via `PolarParams.target_points`; just expose it as a config knob).
- Detect when the user is moving in declination as well as RA (which
  invalidates the assumption) and warn before computing.
- Live update of the predicted residual error during adjustment so
  the user can iteratively tune toward zero without re-running.

### Camera characterization
What "characterization" should mean for an eFinder is narrower than
ZWO's general camera testing:

1. **Black level** (camera offset): integrate dark frames briefly,
   take the median, store as `dark_level`. Cedar-detect supports an
   `estimate_background_region` that effectively does this per-frame,
   but a calibrated baseline lets us start solving on the first frame.
2. **Dead/hot pixel map**: take a long exposure with the lens capped,
   threshold to find permanently-hot pixels, store as a small array.
   Cedar-detect already detects hot pixels per-frame; this would just
   make the per-frame work faster.
3. **FOV calibration**: ✅ DONE. `calibration.py` accumulates 30
   successful solves, commits the median to the config when stddev
   is below 0.05°, then uses tight (0.1°) tolerance for subsequent
   solves. Watches for drift via rolling median; recalibrates if
   the lens is changed or refocused.
4. **Distortion**: ✅ DONE alongside FOV calibration -- same
   accumulator, same commit policy with looser threshold.
5. **Plate scale (arcsec/pixel)**: ✅ DERIVED from calibrated FOV
   and frame_width on commit. Stored as cfg.arcsec_per_pixel.

Still TODO: dark frame and hot pixel calibration. Both require a
"point the scope at a wall and trigger calibration" operation. The
maintenance socket is now in place to host these commands -- the
work is in camera_proc:
- Dark frame: open shutter long, capture N frames, take median per
  pixel, store as a numpy array. Subtract from each subsequent frame
  before publishing.
- Hot pixel map: capture a long exposure, threshold, store the list
  of (y,x) coords. Cedar-detect already does this per-frame; baking
  it in just makes the per-frame work faster and lets us mask in
  the camera before the solver sees it.

### Web UI
✅ DONE (v1). Flask app at `webui/app.py`, runs on port 80 via
`efinder-webui.service`. Talks to the maintenance socket exactly like
`efinder-ctl` does -- holds no state of its own. Pages:
- `/`        dashboard with auto-refreshing pointing, calibration,
             boresight, exposure
- `/polar`   polar alignment workflow (multi-step, live updates)
- `/config`  read-only view of /etc/efinder/efinder.conf
- `/logs`    last N lines of journalctl
- `/update`  trigger efinder-update (via sudoers rule scoped to
             just that one script)
- `/healthz` simple ping endpoint (200 if daemon reachable)

Future improvements:
- Editable config (probably never; ssh + restart is fine)
- Charts of solve history (useful but defer)
- Image preview from a recently-saved frame (requires save_failed_frames
  hookup)
- Authentication (only matters if someone exposes the eFinder to a
  hostile network; not the default deployment)
- Replace Flask's dev server with gunicorn for a tiny perf bump
  (probably never; web UI traffic is one user at a time)

### Captive-portal Wi-Fi fallback
If the configured Wi-Fi credentials don't connect after N attempts,
bring up the `efinder-hotspot` connection and serve a captive portal
that lets the user re-enter credentials. `comitup` does this well
out of the box; `RaspAP` is heavier but has more features.

Defer until v0.8. For now, wrong Wi-Fi credentials = re-flash.

## Tactical TODOs

### Auto-exposure
The solver already knows the detected-star count. Adaptive exposure
algorithm:
- If `n < auto_exposure_target_stars * 0.5`: increase exposure by 1.5x
  (clamped to `auto_exposure_max_s`).
- If `n > auto_exposure_target_stars * 1.5`: decrease by 0.7x
  (clamped to `auto_exposure_min_s`).
- Hysteresis: don't change exposure on every frame; require N
  consecutive frames in the over/under band.
- Clamp number of changes per minute to avoid oscillation.

Need a queue from solver to camera_proc (camera doesn't currently
listen to anything). Keep simple: `exposure_q` with single Float
messages, camera_proc drains and updates picamera2 controls.

### Log/stat exposure to comms or web UI
Right now solve stats only land in journald. The web UI status page
should pull from `latest_solution` directly, but it would be useful
to have a small ring buffer of "last 60 solves" with timing history
for the UI to graph. Probably a new Manager list.

### Boresight reset / show / edit via Unix socket
✅ DONE. `efinder-ctl` is the command-line client; the maintenance
socket lives at `/run/efinder/maint.sock`. Currently supports:
- `efinder-ctl status` / `version` / `ping`
- `efinder-ctl boresight show|center|set Y X`
- `efinder-ctl calibration status|reset`
- `efinder-ctl exposure get|set [--persist]`
- `efinder-ctl gain set [--persist]`
- `efinder-ctl raw '{"cmd":"...","args":{}}'`

The protocol (newline-delimited JSON) is straightforward to extend
when more commands are needed -- see `efinder/maint.py` for the wire
format and `efinder/comms_proc.py::_handle_maint_command` for the
dispatch table.

Future commands likely worth adding when their backing features land:
- `efinder-ctl darkframe capture` (needs camera dark-frame logic)
- `efinder-ctl hotpixels capture` (needs camera hot-pixel logic)
- `efinder-ctl polar status` (needs polar alignment helper)
- `efinder-ctl config show|reload` (needs config-reload broadcast)

### Frame save for diagnostics
`save_failed_frames: true` should cause the solver, on `status=NO_MATCH`
or `TOO_FEW`, to write the most recent frame (with overlays of detected
centroids) to `/var/lib/efinder/captures/YYYYMMDD-HHMMSS.png`. Cap
disk usage at, say, 100 MB; rotate oldest first.

### LX200 sync reply string
Currently we hardcode an M31 string for `:CM#` reply because SkySafari
accepts any short string. Some LX200 dialects expect specific formats.
Check whether SkySafari actually displays the reply string; if so,
craft something useful like "aligned to (RA, Dec)".

### TLS / authentication for LX200 server
None currently. Anyone on the same Wi-Fi can talk to the eFinder.
Probably acceptable for a hobby setup but worth flagging.

### Manager dict performance
`latest_solution` and `shared_cfg` are `multiprocessing.Manager` dicts.
Every read goes through a socket to the manager process. For LX200
polling (a few Hz) this is fine; for the web UI status endpoint it
might add up. If it does, switch to `multiprocessing.shared_memory`
holding a fixed-layout struct with a seqlock. Don't preempt.

### Solve timeout and sigma defaults
The `solve_timeout_ms=1500` and `detect_sigma=8.0` defaults are guesses.
Once we have a few users on real sky, tune from observed metrics.
This is the kind of thing where the web UI status page becomes useful:
expose median solve time, miss rate, average centroid count, then
let users tune from data rather than vibes.

### Solve-from-image fallback
If cedar-detect crashes or the gRPC server is unavailable, we currently
just fail. We could fall back to tetra3's built-in
`get_centroids_from_image`. Slower but robust. Worth doing once we
have the basics solid.

## Known issues to watch

- Manager dict is created in main process but accessed by spawned
  children. Pickling/unpickling on first access; should still work
  but could be a startup hiccup. Verify.
- SHM cleanup on crash: if the launcher dies between `create=True`
  and the `unlink` in `finally`, stale SHM blocks remain in /dev/shm.
  Re-running clears them via the unlink-before-create dance; but a
  systemd `ExecStartPre=/usr/bin/find /dev/shm -name 'efinder_frame_*'
  -delete` would be more robust.
- No watchdog beyond systemd's. If the solver hangs (not crashes),
  systemd won't restart us. Consider a heartbeat: if
  `latest_solution.epoch_monotonic` doesn't update for 60s, the
  launcher kills the solver to force a restart.
