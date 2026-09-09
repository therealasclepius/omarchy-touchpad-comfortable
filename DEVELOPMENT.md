# Comfortable preset preview

This branch extends the per-device Trackpads panel in the upstream
`awkent01.touchpad` plugin. Marketplace releases use the distinct ID
`io.github.therealasclepius.touchpad-comfortable` and retain the existing state
paths so users of this fork keep their settings. See the README for migration
from the old plugin ID.

## Behavior

- An opt-in preset changes pointer sensitivity, native adaptive acceleration,
  scroll speed, tap-to-click, and two-finger physical right-click together.
- Scroll direction, enabled state, and typing suppression stay as selected.
- Undo saves the original five values per device and survives helper restarts.
- Reapplying preserves the original undo point; undo preserves later changes to
  settings outside the preset.
- Workspace swipe setup is documented separately because it is compositor-wide.

## Verification

```sh
python3 test_trackpads.py
python3 test_install.py
node test-selection.js
python3 test_ipc.py  # optional: installed Omarchy modules and local IPC access
```

Backend tests cover isolation, scroll-direction preservation, rollback,
reapplication, and undo. Installation tests run against a fake compositor in
fresh temporary state. UI tests execute actual QML functions to check queue
ordering, double activation, stale responses, and recovery.

The complete panel was loaded successfully in an isolated Quickshell instance
using the installed Omarchy UI components and a fake backend. This verifies
component loading, not physical feel or visual layout across all screen sizes.
Physical tuning so far is limited to one Dell XPS 13 DX13260. The inherited
preview.png predates the preset controls.

## Distribution

Published as a community preview at
https://github.com/therealasclepius/omarchy-touchpad-comfortable.
This is based on awkent01's MIT-licensed Touchpad widget, not an upstream release.
Runtime settings, personal backups, and Git metadata are excluded from the source
archive. Requires the Quickshell shell and Lua-based Hyprland; older Omarchy
configurations are not supported.
