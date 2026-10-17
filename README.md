# ClamshellAwake

Menu bar toggle for macOS's only lid-closed sleep override, `pmset disablesleep`.
Keeps a MacBook awake with the lid shut and no external display, so background
agents keep running.

- **Auto**: on AC, sleep is disabled immediately. On battery the override is held
  while the lid is open, and the grace period (default 10 min, set under "Battery
  Grace"; cancelled if AC returns) starts when the lid *closes*. So unplugging and
  carrying on with the lid open costs nothing, and shutting the lid gives you the
  full grace to plug back in.
  The flag has to already be set at the lid close: macOS goes from lid-closed to
  asleep in about 8 ms, far too fast to react to. The cost is that a lid-open Mac
  left on battery will not idle-sleep (the display still sleeps on its own timer).
  Keying the grace to the unplug instead is what caused the outage in
  `INCIDENT-2026-09-09.md`.
  When the grace expires with the lid shut, the app puts the Mac to sleep itself
  (`IOPMSleepSystem`, the Apple-menu sleep). Clearing the flag alone does nothing
  once the lid is already closed: macOS only consults it at the lid-close moment,
  and the idle timer it falls back to is blocked by any app holding a
  PreventUserIdleSystemSleep assertion. That is `INCIDENT-2026-09-12.md`.
- **Always Awake**: `disablesleep 1`. The Mac never sleeps, lid open or closed, whatever
  the System Settings timers say. The display still turns off on its own timer.
- **Normal Sleep**: `disablesleep 0`, i.e. macOS's own rules. Closing the lid sleeps the Mac
  (unless an external display, keyboard/mouse and power are all attached, Apple's built-in
  clamshell mode). With the lid open, the idle timers from System Settings > Battery apply.
  The menu shows those timers for each power profile, read from `pmset -g custom` when it opens.
- Listens for AC/battery transitions through IOKit (`IOPSCreateLimitedPowerNotification`)
  and for lid open/close on IOPMrootDomain's general interest channel, reading
  `AppleClamshellState`; no polling. A Mac that cannot read its lid state keeps the
  old unplug-keyed grace. Only shells out when the flag actually needs to change.
- The menu spells out what Auto costs: an indented note under it warns that on
  battery the Mac stays awake while the lid is open, and each mode carries a
  tooltip with the full behaviour. Always Awake and Normal Sleep are unaffected by
  the lid logic - only Auto consults the lid state.
- Icon: laptop with a bolt (awake), hourglass (cooldown running), moon (normal sleep).
  In Auto mode the icon is hidden (default; "Hide Icon in Auto Mode" in the menu turns that
  off). It shows in Always Awake and Normal Sleep, and whenever something needs attention
  (missing sudoers rule, pmset failure). To get the menu while hidden, open ClamshellAwake
  again from Spotlight, Finder, Launchpad or `open -a ClamshellAwake`: the icon appears and
  its menu drops; it hides again when the menu closes if Auto is still selected.
- Log: `~/Library/Logs/clamshell-awake.log`.

## Install

```
./install-sudoers.sh   # once, asks for your password; allows exactly two pmset commands
./build.sh             # builds ~/Applications/ClamshellAwake.app and launches it
```

The app registers itself as a login item on first run (System Settings > General > Login Items).
Without the sudoers rule, manual toggles fall back to an admin password prompt and Auto mode
cannot change the flag.

## Notes

- `disablesleep` is global on this macOS: `pmset -c` and `pmset -b` both set the same flag,
  which is why the app manages it by power source instead.
- Quitting the app leaves the flag as it is. `sudo pmset -a disablesleep 0` restores defaults.
