# PostureGuard 坐姿卫士

[![CI](https://github.com/caic99/PostureGuard/actions/workflows/ci.yml/badge.svg)](https://github.com/caic99/PostureGuard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/caic99/PostureGuard)](https://github.com/caic99/PostureGuard/releases)

**English** | [中文](README.zh-CN.md)

A macOS menu bar utility that catches you slouching. It fuses the MacBook's
**hidden lid-angle sensor** with **Vision face-pitch detection** to compute
your true head-down angle, and nudges you when you've been hunching over for
too long.

## How it works

```
                 camera optical axis
                ↗ (rises with the lid: lid − 90°)
       ▢ screen
      ╱ lid angle (hidden HID sensor)
 ▁▁▁▁╱▁▁▁▁ base

true head pitch (vs. horizontal, positive = up)
  = pitchSign × Vision face pitch (camera-relative) + (lid angle − 90°)
```

1. **Lid angle** — Apple Silicon MacBooks ship a hidden hinge-angle sensor
   (HID Sensor page `0x20`, usage `0x8A`). Feature report ID 1 returns a
   little-endian `UInt16` in degrees (0 ≈ closed, 90 = upright, 180 = flat).
   No special permissions required.
2. **Face pitch** — AVFoundation captures the built-in camera at VGA
   resolution and runs Vision's `VNDetectFaceRectanglesRequest`
   (`VNFaceObservation.pitch`, macOS 12+). Frames are analyzed in memory
   only — nothing is stored or uploaded.
3. **Fusion** — face pitch is camera-relative; tilting the screen back raises
   the camera by `lid − 90°`. Compensating for it yields a gravity-referenced
   head pitch, so **re-tilting your screen never causes false alarms and
   never requires recalibration.**
4. **Duty-cycle checks (battery-friendly)** — the camera is *not* always on.
   Every 3 minutes (configurable) it wakes for an 8-second burst, takes the
   median, and shuts off. Idle cost is one timer (~0% CPU, measured); the
   green camera light stays off between checks. On AC power the interval
   automatically shrinks to ⅓ (min 30 s, shown with ⚡ in the menu); on
   battery it returns to the configured value. The first burst doubles as
   baseline calibration — just sit straight.
5. **Judgment** — if a check finds your head more than 15° (configurable)
   below the calibrated baseline, it doesn't alert immediately: it re-checks
   60 seconds later, and only two consecutive bad checks trigger a
   notification + sound (optional voice). Bending down to pick something up
   won't nag you. Detection is suspended when your head is turned away
   (|yaw| > 35°) or you leave. A continuous "realtime" mode (camera always
   on, ~0.5–1 W) is available mainly for debugging.

## Install

Download the latest `PostureGuard.app.zip` from
[Releases](https://github.com/caic99/PostureGuard/releases), unzip, and run.
The app is ad-hoc signed, so on first launch you may need to clear quarantine:

```bash
xattr -cr PostureGuard.app
open PostureGuard.app
```

Or build from source:

```bash
./make-app.sh                 # builds build/PostureGuard.app
open build/PostureGuard.app   # first launch asks for camera permission
```

Launch at login: System Settings → General → Login Items → add
`PostureGuard.app`.

> Note: with ad-hoc signing the signature hash changes on every rebuild, so
> macOS treats each rebuild as a new app — the camera permission prompt
> reappears once per rebuild. Day-to-day use is unaffected.

## Usage

Menu bar states: `🙆` good posture · `🙇` slouching · `🚨` alert fired ·
`🪑📐` calibrating · `🪑` no face · `🪑⏸` paused · `🪑📷✕` no camera
permission. Emoji-only by default; enable "show angle in menu bar" to append
the live deviation (e.g. `🙇 -17°`).

From the menu you can: recalibrate to your current posture, pause/resume,
set the alert threshold (10/15/20/25°), set the check interval
(realtime / 1 / 3 / 5 min), toggle the menu bar angle display, and toggle
voice alerts.

## Debugging

```bash
open build/PostureGuard.app --args --debug
tail -f /tmp/posture-guard.debug.log
```

Each line logs `lid` (lid angle), `vision` (raw Vision pitch), `head`
(compensated head pitch), `dev` (deviation from baseline), and the state.
**Verify direction**: `dev` should go negative when you bow your head; if it
moves the opposite way, launch with `--invert-pitch` (the stale baseline is
discarded and recalibrated automatically).

CLI options: `--threshold N` `--check-interval N` (0 = realtime)
`--duration N` (realtime mode only) `--interval N` `--voice`
`--invert-pitch` `--no-lid` `--debug` `--reset` (clear calibration and
settings).

## Limitations

- The lid-angle sensor exists only on recent Apple Silicon MacBooks. Without
  it the app falls back to raw face pitch (recalibrate after re-tilting the
  screen).
- Assumes the base sits flat on a desk. On a lap or tilted stand the baseline
  shifts — just recalibrate.
- Clamshell mode with an external display won't work — the built-in camera is
  covered.
- Apple never documented the sign convention of `VNFaceObservation.pitch`.
  Measured empirically (macOS 26.5, correlation −0.95 between pitch and the
  face's vertical position in frame): **positive pitch = head down**, and the
  default `pitchSign = -1` is set accordingly. If a future OS flips it, launch
  with `--invert-pitch`.

## License

[MIT](LICENSE)
