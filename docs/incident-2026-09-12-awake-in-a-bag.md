# Incident 2026-09-12 19:58 – 2026-09-13 00:01 (4h03m awake in a bag)

Auto mode, grace = 300s. MacBook unplugged with the lid shut, carried for
~3 hours, arrived hot. Never slept. Battery 79% -> 31%.

## Timeline (app log + `pmset -g log` + `pmset -g assertions`)

| Time | Event | Source |
|---|---|---|
| 09-10 17:00:21 | lid closed (stayed closed from here) | app log |
| 09-12 19:52:56 | AC dropped. `lid closed on battery: normal sleep in 299s unless AC returns` | app log |
| 19:58:08 | grace expired -> `SleepDisabled=0 (battery for 300s)` | app log |
| 19:58 – 00:01 | **no sleep entry of any kind**. Only assertion churn (cloudd, apsd, AddressBookSourceSync) and hourly powerd "inactivity prediction" ticks | pmset log |
| whole window | `Resolve` (DaVinci Resolve, pid 46047, launched 09-11 13:14) holding `PreventUserIdleSystemSleep "Background Activity"`, 34h49m old at 00:04 | assertions |
| whole window | `coreaudiod` holding `PreventUserIdleSystemSleep` for Resolve (BuiltInSpeakerDevice) and for an iOS Simulator audio device, both 4h11m old at 00:04 (i.e. since ~19:53) | assertions |
| 00:01:26 | lid opened -> `SleepDisabled=1 (lid)` | app log |

## Root cause

The app did what it was written to do: 5 minutes after the unplug it set
`disablesleep 0`. That was not enough, for two reasons that stacked.

**1. Clearing `disablesleep` with the lid already shut does not sleep the Mac.**
macOS only consults the flag on the lid-close *transition* (09-09 incident:
`ClamshellState. Closed : 1 ... isSleepDisabled : 0` -> `Entering Sleep state
due to 'Clamshell Sleep'` 5 seconds later). Here the lid had been closed for two
days. Flipping the flag afterwards leaves the Mac in ordinary lid-closed-awake
state, and the only thing that can sleep it from there is the idle timer.

**2. The idle timer was held off by assertions.** DaVinci Resolve holds a
permanent `PreventUserIdleSystemSleep "Background Activity"` while it is open,
and coreaudiod holds one on its behalf for the speaker device. Idle sleep never
came. Every earlier grace expiry in the log (09-03 .. 09-09) happened to be
followed by an idle sleep within 5–15 minutes because nothing was asserting at
the time; the design was relying on luck.

## Fix (shipped)

At grace expiry, after clearing the flag, if the lid is closed and still on
battery the app calls `IOPMSleepSystem` (what the Apple menu's Sleep does).
Forced sleep ignores `PreventUserIdleSystemSleep` assertions and needs no root.
Logged as `lid closed: sleeping now`, or a WARNING if the call fails.

Verified 2026-09-13 00:25 with grace = 60s, lid shut, Resolve still open and
still holding its assertion:

    00:24:50 lid closed on battery: normal sleep in 59s unless AC returns
    00:25:51 SleepDisabled=0 (battery for 60s)
    00:25:51 lid closed: sleeping now
    00:25:51 system sleeping (ac=false)

powerd: `Entering Sleep state due to 'Software Sleep pid=53967'` (the app).
Slept 24 minutes until the lid was opened.

## Thermal record (unified log, thermalmonitord `mTPL` / powerexperienced `kThermalPressureContext`)

Note: from zsh, `log show` hits the shell's builtin `log`; use `/usr/bin/log`.
`pmset -g therm` reports nothing on Apple silicon and is not evidence.

| Time | Thermal pressure level |
|---|---|
| before 20:32 | 0 (nominal) |
| 20:32:25 | 1 |
| 20:32:26 | 2 |
| 20:36:00 | 1 |
| 20:40:59 | 2, held until the lid opened |
| 00:01:53 | 1 |
| 00:02:29 | 0 |

So 40 minutes into the trip the Mac hit level 2 and sat there for ~3h20m.
Level 2 is the "serious" tier (scale 0 nominal .. 3 critical): the OS was
actively throttling the SoC to hold temperature. It never reached 3 and there
was no thermal shutdown.

## Damage check

- Battery gauge (AppleSmartBattery): lifetime max temperature 42 °C, 9 cycles,
  raw max capacity 6333 mAh vs 6249 design (101%). 42 °C is the top of the
  normal band for lithium cells and was held for at most a few hours; no
  measurable capacity loss.
- Throttling is the designed response and keeps the die inside spec. Nothing
  in the record indicates damage. What cannot be checked from software is
  whether the enclosure or case material took any heat marks.
