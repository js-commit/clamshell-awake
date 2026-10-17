# Outage 2026-09-09 17:39:51 – 17:55:05 (15m14s)

Auto mode, grace = 300s. The Mac (running background jobs) was unreachable for 15 minutes.

## Timeline (app log + `pmset -g log` + powerd unified log)

| Time | Event | Source |
|---|---|---|
| 16:30:02 | AC dropped, `battery: normal sleep in 299s unless AC returns` | app log |
| 16:35:11 | grace expired → `SleepDisabled=0 (battery for 300s)` | app log |
| 16:35–17:39 | **lid still open, user still working** (display on to 17:37:52, HID activity to 17:32) | powerd |
| 17:39:46 | lid closed. `ClamshellState. Closed : 1. ClamshellSleepState: isSleepDisabled : 0` | powerd |
| 17:39:51 | `Entering Sleep state due to 'Clamshell Sleep' ... Using Batt (Charge:72%)` | pmset |
| 17:39:52 | wake queued: `dasd SleepService deltaSecs=912 wakeAt=17:55:05` | pmset |
| ~17:44–17:46 | AC arrives. **No wake.** (MTP heartbeat gap 17:44:10→17:45:51; AOP gyro 17:45:43/46 = machine handled) | kernel |
| 17:55:05 | `DarkWake from Deep Idle : due to NUB.SPMI0Sw3IRQ ... rtc/SleepService` — Charge **83%** | pmset |
| 17:55:05 | app's IOKit notification finally fires → `power source: AC` → `SleepDisabled=1` | app log |
| 17:55:05 | `DarkWake to FullWake ... due to Notification Using AC` | pmset |

Battery went 72% → 83% *while asleep*: AC was attached mid-sleep and the Mac
never noticed it in a way that could wake it.

## Root cause

Two independent gaps compounded.

**1. The grace timer expired an hour before it mattered.** Auto keys the grace to
the *unplug*, not to the lid close. `SleepDisabled` went to 0 at 16:35 while the
lid was open and in use; by 17:39 the override was long gone, so lid-close slept
instantly (8 ms from clamshell-changed to WillSleep — unwinnable race).

**2. AC attach during sleep produced no wake event.** Every prior recovery in the
log dark-woke from an SMC port-plug interrupt:

    09-04 01:09:13  DarkWake ... due to smc.sysState.Wake(0x70070000) USB-C_plug ...
    09-04 23:47:14  DarkWake ... due to smc.sysState.Wake(0x70070000) USB-C_plug ...
    09-08 20:29:58  DarkWake ... due to smc.sysState.Wake(0x70070000) ...

Today there is no such entry. The adapter is a 140W USB-C ("pd charger"), same as
before, so the likely difference is that the cable was **already seated in the Mac
and power arrived at the far end later** (brick to wall / strip / dock upstream).
No port attach at the Mac = no SMC wake = the Mac slept on and just charged.

The app cannot run while asleep, so it had no way to see AC.

**Recovery was not the app's doing.** The 17:55:05 wake was the Power Nap
SleepService heartbeat queued at sleep time. The outage was therefore bounded by
one SleepService interval (~15–20 min, same cadence as the ~30 dark wakes on
09-08) — and only because `powernap 1` is set for Battery. Do not turn that off.

## Why `acwake` can't fix it

Not supported on this Mac. `pmset -g cap` lists: displaysleep, disksleep, sleep,
womp, standby, powernap, ttyskeepawake, hibernatemode, hibernatefile,
tcpkeepalive, lowpowermode, highpowermode. No `acwake`.

## Fix (shipped)

Option (b) below. Auto now holds `disablesleep=1` on battery while the lid is
open and starts the grace at the lid close. Replaying this incident against it:
the flag would still be 1 at 17:39:46, no clamshell sleep, grace running; AC
lands ~17:45 and the app is awake to see it; grace cancelled, no outage.

Verified 2026-09-09 18:42 on a physical lid flip:

    18:42:07 lid open
    18:42:12 lid closed

Both notifications delivered. powerd logged the same
`ClamshellState. Closed : 1. ClamshellSleepState: isSleepDisabled : 0` line as at
17:39:46, but with **no** `kIOMessageSystemWillSleep` after it, and the machine
has not slept since. `AppleClamshellState` matches `ioreg` in both positions.

(`AppleClamshellCausesSleep` reads Yes here and is advisory only - it was No
earlier merely because the Mac had woken with the lid already shut, so powerd was
suppressing clamshell sleep. The code does not read it.)

## Fix options considered

**(a) Guarantee a wake.** On `willSleep` while auto+battery, `pmset schedule wake`
a few minutes out; re-evaluate on wake. Caveats: needs root, and the sudoers rule
is deliberately exact-argv, so it needs a wildcard for `schedule wake`/
`cancel`. Worse, the 09-08 log shows ~30 SleepService dark wakes with zero app log
lines — `NSWorkspace.willSleep/didWake` do not fire in dark wake, so the app can't
reschedule after a wake that finds it still on battery. Needs
`IORegisterForSystemPower` (delivers dark-wake messages, requires
`IOAllowPowerChange` acks) or pre-scheduling several wakes.

**(b) Key the grace to lid-close, not unplug.** Hold `SleepDisabled=1` on battery
while the lid is open; start the grace when the lid closes; drop to 0 only if AC
hasn't returned. Needs `kIOPMMessageClamshellStateChange` on IOPMrootDomain.
Cost: suppresses idle sleep lid-open on battery, and Battery is currently
`sleep 1`. Mitigable via `screensDidSleep`/`DidWake`, but that's the full redesign.

## No-code mitigation

Plug the USB-C end into the **Mac** after the brick is already live. That is what
dark-woke it in all three prior recoveries.
