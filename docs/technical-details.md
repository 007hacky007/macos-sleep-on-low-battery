# Technical details

How Battery Sleep Guard works inside, what it stores and where. For the overview and build steps see the [README](../README.md).

## Permissions

| What | Why | How it is granted |
| --- | --- | --- |
| Notifications | Banner "Battery reached 25%. Putting Mac to sleep." | macOS asks on first launch. Change later in System Settings > Notifications > Battery Sleep Guard. |
| Login item | "Launch at login" uses `SMAppService.mainApp` | Turn it on in the app's Settings. If macOS reports that approval is needed, enable it in System Settings > General > Login Items. |
| Running `pmset sleepnow` | Forcing sleep | No permission needed. Any logged-in user may request sleep, no admin password or sudo involved. |
| Battery information | IOKit power source APIs | No permission needed. |

App Sandbox is turned off (`com.apple.security.app-sandbox = false` in `BatterySleepGuard.entitlements`). The app is not meant for the Mac App Store, and a sandboxed app passes its sandbox on to child processes, which would put `pmset` under the same restrictions. Hardened Runtime is on. No other entitlements are used.

## How it works

- **Monitoring.** `BatteryMonitor` reads the internal battery through `IOPSCopyPowerSourcesInfo` and `IOPSGetPowerSourceDescription` every 30 seconds. It also reacts right away to power source changes such as plugging in or unplugging.
- **Trigger.** The Mac goes to sleep when the guard is enabled, the Mac is on battery, the level is at or below the threshold, and the guard has not fired yet in this cycle. After firing, `actionTriggered` stays set until the Mac wakes.
- **Wake.** On `NSWorkspace.didWakeNotification` the app starts a new cycle: it clears `actionTriggered`, resets the start time, and drops old samples, since a sleep gap would distort the drain rate. If the Mac slept or rebooted while the app was not running, the app notices at launch (from `kern.waketime` and `kern.boottime`) and starts a new cycle too.
- **No sleep loop after wake.** The guard fires when the battery *drops to* the threshold. A cycle is armed only after the battery has been seen above the threshold. If you wake the Mac at 24% with a 25% threshold, it stays awake so you can plug in. The status shows "Paused until battery is above 25%". The cycle arms again once the battery charges above the threshold. Raising the threshold above the current level does not put the Mac to sleep on the spot for the same reason.
- **Drain rate.** The app keeps the last 20 samples. The battery reports whole percents, so 20 back to back 30 second readings would cover only 10 minutes. A sample is therefore stored when the percentage or power state changes, plus a heartbeat every 5 minutes. The rate is the least squares slope over the latest uninterrupted discharge. It needs at least 3 points across at least 5 minutes before a value is shown.
- **Keep awake.** Holds a `PreventUserIdleSystemSleep` assertion, or `PreventUserIdleDisplaySleep` when "Keep display on" is checked, for a chosen duration or until turned off. You can see it in `pmset -g assertions` as "Battery Sleep Guard keep awake". Like Amphetamine without its helper, it blocks idle sleep only. Closing the lid still sleeps the Mac. The session ends when the app quits.
- **Early warning.** With "Warn 10 minutes before sleep" on (default), one notification per cycle is posted when the estimated sleep time comes within 10 minutes: "Battery should reach 25% in about 8 min (at 14:32). The Mac will go to sleep then unless you plug in."
- **Keep awake options.** The menu shows the remaining time of a timed session. "Only while on AC power" suspends keep awake on battery, so a forgotten session cannot drain it.
- **History retention.** Settings offers 1, 7 or 30 days of history (default 7) and a "Clear" button that empties both files.
- **Threshold beats keep awake.** While the guard is enabled and the Mac is on battery at or below the threshold, the app releases its assertion. When the battery drops to the threshold, the assertion is released before `pmset sleepnow` runs. If the guard is paused after a wake below the threshold, the Mac can still idle sleep normally. On AC power, or above the threshold again, keep awake resumes by itself.
- **Power and temperature.** Read from the `AppleSmartBattery` IORegistry entry: battery flow from voltage times amperage (negative while discharging, positive while charging), system load from `PowerTelemetryData/SystemLoad` (what the whole Mac consumes, whatever the source), adapter input from `PowerTelemetryData/SystemPowerIn` (on AC, roughly system load plus charging power), temperature from `Temperature` (top level on older Macs, inside `BatteryData` of `AppleSmartBatteryPack` on Apple Silicon with recent macOS). CPU temperature is the average of the per-core SMC sensors for the chip generation (M1 to M6 key lists as used by the Stats app, CPU die or proximity sensor on Intel); one reading is about 10 IOKit calls, roughly 1.5 ms, and it is only read while the menu bar window is open. Rows the Mac does not report are hidden. While the menu bar window is open, readings refresh every 5 seconds instead of 30.
- **Menu bar.** The system already shows the battery level, so the icon shows the guard's state: filled moon when armed, outline moon when paused, on AC or already triggered, plain moon when disabled, a cup while keep awake holds an assertion, a warning sign on errors. Settings can add text next to it: time until sleep, battery percentage with time until sleep, keep awake remaining time, battery power or temperature.
- **History and statistics.** Every reading is recorded (at most one row per 30 seconds unless the level or power state changed) to `history.csv`, and every state change (launch, wake, cycle reset, keep awake on/off/paused, sleep triggered, sleep failed, battery errors, guard on/off, plugged in, unplugged, display off/on, early warning) to `events.csv`, both in `~/Library/Application Support/BatterySleepGuard/`. Rows older than the configured retention (1, 7 or 30 days, default 7) are dropped at launch and hourly. The same events go to the unified log at notice level: `/usr/bin/log show --last 1d --predicate 'subsystem == "BatterySleepGuard"'` (the full path matters in zsh, where `log` is a shell builtin). "Statistics" in the menu opens a window with charts of battery level, power, temperature and estimated time until the threshold over the last 1 h, 6 h, 24 h or 7 d. The power chart shows battery flow as a signed area (green above zero while charging, orange below zero while discharging) with system load and adapter input as lines. AC periods are shaded green on every chart and events are vertical marks. Hovering any chart scrubs all four with a vertical rule and shows the nearest sample's values. A summary line gives the range's average drain (discharging stretches only), time weighted average system load, energy used (trapezoid integral of system load) and time on battery. Rows are averaged into time buckets, and lines break across gaps longer than 5 minutes (sleep, app not running) instead of being drawn through them. The window can reveal the files in Finder or export the shown range as CSV.
- **Processes.** Every 10 seconds the app reads the CPU time and idle wake-ups of every process it may inspect through libproc (`proc_pidinfo`, `proc_pid_rusage`; no subprocess, no root), the parent of every process through `sysctl`, and the system-wide busy CPU time through `host_statistics`, and keeps 5 minutes of snapshots. The "Processes" window rolls processes up under their top-level application the way Activity Monitor does (a terminal row includes the shells, builds and tools started from it) and lists the busiest applications with CPU percent (100 = one core), an approximate power figure, wake-ups per second and their three busiest members; the menu shows the top two. macOS gives a non-root app no per process energy counter, so the power figure is the application's share of the system-wide CPU time, applied to the measured system load above the last day's idle floor; CPU burnt by unreadable processes stays unattributed, and the column shows "-" when there is less than 0.5 W to attribute. Display, GPU and processes of other users (including system daemons such as WindowServer) are not attributed.
- **Sleep failure.** If `pmset` fails, the app asks IOKit directly (`IOPMSleepSystem`). If that fails too, the error is shown in the menu. "Reset statistics" starts a new cycle and re-arms the guard.

## Stored data

`UserDefaults` domain `com.example.BatterySleepGuard`:

| Key | Contents |
| --- | --- |
| `enabled` | Guard on or off |
| `thresholdPercentage` | Threshold, 5 to 95, default 25 |
| `monitoringStartDate` | Start of the current cycle |
| `samples` | JSON array of recent samples |
| `actionTriggered` | Whether the guard fired in this cycle |
| `armed` | Whether the battery was above the threshold in this cycle |
| `keepDisplayAwake` | Keep awake also keeps the display on |
| `keepAwakeDuration` | Last chosen keep awake duration in minutes, 0 means indefinitely |
| `menuBarText` | Text next to the menu bar icon |
| `keepAwakeOnlyOnAC` | Keep awake suspended while on battery |
| `historyRetentionDays` | 1, 7 or 30 |
| `earlyWarning` | Notification 10 minutes before the expected sleep |

Reset everything with `defaults delete com.example.BatterySleepGuard` while the app is not running.

Files in `~/Library/Application Support/BatterySleepGuard/`:

| File | Contents |
| --- | --- |
| `history.csv` | One row per recorded reading: timestamp (UTC), percentage, power source, charging, battery watts, system watts, temperature, drain rate, time to threshold, keep awake, status, adapter input watts |
| `events.csv` | Timestamp, event kind, message |

Both keep the configured retention (1, 7 or 30 days, default 7). "Clear" in Settings empties them, or delete them while the app is not running.

## Project layout

```
BatterySleepGuard/
  App/BatterySleepGuardApp.swift       MenuBarExtra scene and app delegate
  Models/
    BatterySample.swift                Samples, live reading, sample history window
    BatteryTelemetry.swift             Watts and temperature parsed from IORegistry
    AppSettings.swift                  Settings, keep awake durations, menu bar text options
    SleepTriggerPolicy.swift           When to fire, arming, when keep awake is allowed
    DrainRateCalculator.swift          Drain rate and time to threshold
    HistoryEntry.swift                 History rows, events, CSV coding
    ProcessUsage.swift                 Process snapshots and the CPU share calculator
    ChartSeries.swift                  Downsampling and event labels for charts
  Services/
    BatteryMonitor.swift               IOKit reads, 30 s / 5 s timer, power change events
    CPUTemperatureSensor.swift         Average CPU core temperature from the SMC
    SleepController.swift              pmset sleepnow with IOKit fallback
    KeepAwakeService.swift             Idle sleep assertion for keep awake
    NotificationService.swift          User notifications
    PersistenceService.swift           UserDefaults storage
    HistoryStore.swift                 CSV history and events files, configurable retention
    ProcessEnergyMonitor.swift         libproc sampling every 10 s, 5 minute window
    LoginItemManager.swift             SMAppService login item
    SystemClock.swift                  Last wake or boot time
  ViewModels/MenuBarViewModel.swift    State, cycle logic, user actions
  Views/
    MenuBarView.swift                  Menu bar label and main window
    SettingsView.swift                 Menu bar text, early warning, history retention, launch at login, notifications
    StatisticsView.swift               Statistics window with charts
    ProcessesView.swift                Processes window, applications with their child processes
    Formatting.swift                   Durations, watts, temperature
  Assets.xcassets                      App icon, rendered by scripts/make-icon.swift
  Info.plist                           LSUIElement = YES (no Dock icon)
  BatterySleepGuard.entitlements       App Sandbox off
BatterySleepGuardTests/                Unit tests (BatteryLogicTests, HistoryTests, ProcessUsageTests, BatchTests), plus integration tests against the real IOKit and libproc
project.yml                            XcodeGen spec for the Xcode project
scripts/make-icon.swift                Draws the 1024 px icon: `swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon.png`, then `sips -z` it into the appiconset sizes
```

## Limitations

- Desktop Macs without a battery show "No battery detected", and the guard does nothing.
- Battery percentage comes in whole numbers, so the first drain estimate needs a few minutes of discharge.
- Keep awake does not prevent sleep when the lid is closed.
- Per process power is an estimate from CPU time; it cannot see GPU, display or other users' processes.
