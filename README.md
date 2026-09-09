# Touchpad Comfortable — Omarchy bar widget

A bar widget for [Omarchy](https://omarchy.org) with independent controls for
multiple trackpads. Select a device at the top of the panel before adjusting it.

## Comfortable preset

Open the Touchpad panel, select your trackpad, and choose **Apply preset**.
This opt-in starting point was tuned on a Dell XPS 13 DX13260, inspired by
MacBook trackpad interaction. Adjust the sliders for your hardware and preference.
Installation alone does not apply the preset.

| Control | Preset |
| --- | --- |
| Pointer speed | 0.20 |
| Acceleration | Adaptive (libinput's native curve) |
| Scroll multiplier | 0.65 |
| Tap to click | On |
| Two-finger physical right-click | On |

Your scroll direction, typing suppression, and enabled/disabled choice are
preserved. The preset applies only to the selected trackpad. **Undo preset**
restores the five affected settings from before the first application, even after
restarting. Reapplying keeps that original undo point. Undo also replaces manual
changes to those five settings made since applying; later scroll-direction
changes are preserved.

This does not reproduce Apple's acceleration curve, add system-wide momentum
scrolling, or adjust physical click force/haptic feedback. Those depend on the
hardware, driver and application. Other trackpads have not been physically
evaluated; this is a tunable starting point, not a universal calibration.

### Optional three-finger workspace swipes

Gestures are separate because Hyprland workspace gestures affect all trackpads
and may conflict with existing gestures or three-finger dragging. To opt in,
back up `~/.config/hypr/input.lua`, check for an existing three-finger horizontal
gesture, and add this once (or update the existing rule):

```lua
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-- Swipe right to go right, left to go left. Independent of scroll direction.
hl.config({ gestures = { workspace_swipe_invert = false } })
```

Run `hyprctl reload`, then `hyprctl configerrors`. Remove the added lines or
restore your backup to undo. This requires Lua-based Hyprland; do not paste Lua
into an older `hyprland.conf` setup.

References: [Hyprland input settings](https://wiki.hypr.land/Configuring/Basics/Variables/),
[per-device settings](https://wiki.hypr.land/configuring/core/devices/), and
[gestures](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/).

## Controls

- Enable or disable the selected trackpad.
- Scroll speed (0.1–2.0) and pointer speed (−1.0–1.0).
- Pointer acceleration: adaptive when on, flat when off. Adaptive acceleration
  makes faster finger movements travel farther; it uses libinput's native curve.
- Natural scrolling, tap to click, disable while typing, and clickfinger behavior.
- Keyboard navigation through device selection, sliders, and switches.

Both Apple Magic Trackpad interfaces share one set of Apple settings. The known
Dell touchpad is labeled Dell; other devices containing `touchpad` or `trackpad`
in their Hyprland name are listed by that name. Disconnected devices retain their
saved settings, and newly attached devices are discovered during state refreshes.

## Requirements and installation

Requires Omarchy's Quickshell shell and Lua-based Hyprland configuration, Python 3,
`hyprctl`, and GNU `timeout` (coreutils).

```sh
omarchy plugin add https://github.com/therealasclepius/omarchy-touchpad-comfortable.git --enable
```

This is a community preview based on
[awkent01's Touchpad widget](https://github.com/awkent01/omarchy-touchpad-widget),
with the original MIT license and attribution retained. It has its own plugin ID,
`io.github.therealasclepius.touchpad-comfortable`, for independent marketplace
installation. No administrator access is needed. Enable only one touchpad
controller at a time to avoid conflicting settings.

### Switching from the earlier Comfortable preview

Earlier releases of this fork used `awkent01.touchpad`. The plugin manager cannot
update that installation directly to a different ID. While the shell is running,
back up the old plugin and bar configuration, remove the old installation, then
add this one:

```sh
backup_dir="$HOME/.local/share/touchpad-migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp -a "$HOME/.config/omarchy/plugins/awkent01.touchpad" "$backup_dir/"
cp -a "$HOME/.config/omarchy/shell.json" "$backup_dir/"
omarchy plugin disable awkent01.touchpad
omarchy plugin remove awkent01.touchpad --yes
omarchy plugin add https://github.com/therealasclepius/omarchy-touchpad-comfortable.git --enable
```

Saved per-device settings and the preset undo point from this fork are retained
in the existing state paths listed below. Do not delete those state files during
migration. Bar placement may need adjusting through Omarchy's bar settings.
External shortcuts using the old IPC target must use the new ID below.

These steps also replace the original upstream widget if it is installed;
settings from the original upstream implementation are not guaranteed to migrate.
The backup retains the old code and bar configuration for recovery.

For an existing installation under the new ID:

```sh
omarchy plugin update io.github.therealasclepius.touchpad-comfortable
```

Settings initialize automatically on the first state read. Existing legacy
pointer settings are imported where recognized. Subsequent reads preserve saved
settings; changing one device does not replace another device's settings.

Structural QML changes require a shell restart if hot reload leaves the old
component running:

```sh
omarchy restart shell
```

## Keyboard commands and IPC

The inherited Omarchy panel handler exposes the plugin command target:

```sh
omarchy-shell io.github.therealasclepius.touchpad-comfortable open
omarchy-shell io.github.therealasclepius.touchpad-comfortable close
omarchy-shell io.github.therealasclepius.touchpad-comfortable toggle
omarchy-shell io.github.therealasclepius.touchpad-comfortable show
omarchy-shell io.github.therealasclepius.touchpad-comfortable hide
```

## Persistence and process behavior

`trackpads.py` serializes state reads and writes with a file lock and writes
settings using temporary files and atomic replacement. Settings are stored under
`$XDG_STATE_HOME`, defaulting to `~/.local/state`:

- `omarchy/local-touchpads/settings.json` stores per-device values.
- `omarchy/toggles/hypr/zz-local-touchpads.lua` contains literal per-device rules
  loaded by Omarchy on Hyprland configuration reloads.

These paths retain compatibility with the initial local customization. The
helper emits per-device `hl.device` rules, not shared `hl.config` settings. On a
reported save failure it attempts to restore the previous selected-device rules.
The two files are replaced individually, not as one filesystem transaction.

The panel bounds state reads to 15 seconds and writes to 10 seconds, followed by
a two-second forced-kill deadline. A timed-out action releases the queue and
reports an error. Poll responses captured before a newer edit are discarded and
replaced with a fresh read after pending work finishes.

The panel displays its saved settings. Changes made by separate configuration
tools are not automatically imported into the saved per-device values.

## Development and verification

```sh
python3 test_trackpads.py
node test-selection.js
python3 test_install.py
python3 test_ipc.py  # On an Omarchy host; requires local IPC sockets
```

The installation test copies only Git-tracked files into a temporary plugin
folder, uses temporary state and a fake compositor, and checks first-run setup,
independent writes, device discovery, and recovery from a blocked lock. Stage
new source files before running this test.

The UI tests execute functions extracted from the actual QML source with
controlled callback ordering. They exercise device switching, stale reads,
debounced edits, timeout recovery, and command configuration. They also verify
the timeout wrapper against a real stalled child process. A live Omarchy UI
check is still appropriate before release.

## Uninstall

```sh
omarchy plugin remove io.github.therealasclepius.touchpad-comfortable
```

Removing the plugin does not remove the saved state or generated device rules.
To reset those overrides, remove the two state files listed above and reload
Hyprland; back up any settings you want to preserve first.

## License

MIT. Based on the original widget by awkent01.
