# Trinetra toolkit — roadmap

**Decision (4 Nov 2026, Animesh):** Trinetra takes on the whole feature set of a Mac menu bar
toolkit such as Vorssaint, as optional modules beside the keep-awake core.

**Ground rules**

- **Our own code.** Vorssaint is GPL-3.0 with a trademark policy; Trinetra is MIT. No Vorssaint
  code, assets, names or look are copied. Features are re-implemented from Apple's documented APIs
  (and the few well-known undocumented ones noted below).
- **Modules, all off by default.** `Module` in `TrinetraCore/Modules.swift`, stored in
  `settings.json` → `modules`. A module that is off runs nothing: no timers, observers, event taps
  or permission prompts. The keep-awake core never depends on a module.
- **Permissions only when a module needs them,** requested when it is switched on, with a line in
  the menu explaining why.
- **Privacy stays.** No telemetry. Network use is limited to modules whose purpose is the network
  (speed test, app updates, Homebrew) and they say so in their summary. Telegram remains the core's
  only network use.
- **Root stays narrow.** The helper keeps its fixed-argv XPC methods. Fan control and Bluetooth
  get their own methods with fixed arguments and range checks (phase 8), never a shell.
- Logic that can be pure goes into `TrinetraCore` with unit tests; AppKit stays in `App/`.

## Phases

| Phase | Module (`Module` raw value) | macOS API | Permission | Min macOS | Status |
|---|---|---|---|---|---|
| 1 | System monitor (`system-monitor`): CPU per core, GPU, memory + pressure + swap, temperatures, battery health/cycles/temperature/time left, power draw, network rates, disk free, CPU per agent, menu bar readout | Mach `host_processor_info`, `host_statistics64`, `sysctl`, IOKit `IOAccelerator` / `AppleSmartBattery`, IOHIDEventSystem (dlsym), `getifaddrs`, `proc_pid_rusage` | none | 13 | **built** |
| 1 | Health alerts (`health-alerts`): sustained CPU, temperature, thermal throttling, memory pressure, low disk, low battery | `UNUserNotificationCenter`; phone via Telegram when that lands | Notifications | 13 | **built** |
| 2 | Finder cut and paste (`finder-cut`) | CGEvent tap on ⌘X/⌘V while Finder is frontmost → `NSFileManager` move | Accessibility | 13 | planned |
| 2 | Quit on close (`quit-on-close`) | AX observer `kAXUIElementDestroyedNotification` per chosen app | Accessibility | 13 | planned |
| 2 | ⌘Q / ⌘W protection (`quit-protection`) | CGEvent tap, hold-to-confirm | Accessibility | 13 | planned |
| 2 | Clipboard history (`clipboard-history`), plain-text paste, auto-clear, link tracking strip | `NSPasteboard.changeCount` polling, local store | none | 13 | planned |
| 3 | Window snapping (`window-snapping`): halves, thirds, sixths, corners, centre, gaps, edge snap, modifier-drag | AX `kAXPositionAttribute` / `kAXSizeAttribute`, CGEvent tap | Accessibility | 13 | planned |
| 3 | Window switcher (`window-switcher`) with thumbnails | `CGWindowListCopyWindowInfo`, ScreenCaptureKit | Accessibility, Screen Recording | 13 (14 for SCK thumbnails) | planned |
| 3 | Dock previews and click actions (`dock-previews`) | AX on the Dock process, ScreenCaptureKit | Accessibility, Screen Recording | 14 | planned |
| 4 | Volume mixer (`volume-mixer`), boost | Core Audio process taps + aggregate device | System Audio Recording | 14.4 | planned |
| 4 | Per-app output (`audio-routing`) | Core Audio process taps | System Audio Recording | 14.4 | planned |
| 4 | Microphone mute / pin (`mic-mute`) | Core Audio `kAudioDevicePropertyMute`, default input device | none | 13 | planned |
| 5 | Command bar (`command-bar`): apps, calculator, units, web, files, menu commands | `NSMetadataQuery`, AX menu bar | Accessibility (menu commands) | 13 | planned |
| 5 | Snippets (`snippets`) | CGEvent tap + paste | Accessibility | 13 | planned |
| 5 | Quick toggles (`quick-toggles`): dark mode, hidden files, eject, empty Trash, Do Not Disturb | AppleScript / `defaults` / DiskArbitration | Automation | 13 | planned |
| 5 | Colour picker (`color-picker`) | `NSColorSampler` | none | 13 | planned |
| 5 | Copy text from screen (`text-recognition`) | ScreenCaptureKit + Vision `VNRecognizeTextRequest` | Screen Recording | 14 | planned |
| 6 | Screenshots (`screenshots`) with editor, scrolling capture | ScreenCaptureKit `SCScreenshotManager` | Screen Recording | 14 | planned |
| 6 | Screen recording (`screen-recording`) with system + mic audio | ScreenCaptureKit + AVAssetWriter | Screen Recording, Microphone | 14 | planned |
| 7 | Cleaner (`cleaner`) | file scan of caches/logs, Trash | Full Disk Access (optional) | 13 | planned |
| 7 | Uninstaller (`uninstaller`) with leftovers | bundle id → Library paths | Full Disk Access (optional) | 13 | planned |
| 7 | App updates (`app-updates`) | Sparkle appcasts / Mac App Store lookup | network | 13 | planned |
| 7 | Homebrew (`homebrew`) | `brew` CLI | network | 13 | planned |
| 7 | Speed test (`speed-test`) | `networkQuality` (built into macOS) | network | 13 | planned |
| 8 | Fan control (`fan-control`), beta | AppleSMC user client via the helper, new fixed XPC method, range-checked; restores Auto on quit/crash | admin (helper) | 13 | planned |
| 8 | Display brightness (`display-brightness`): per display, DDC on external, XDR headroom | DDC over `IOAVService` (Apple silicon), gamma dimming fallback | none | 13 | planned |
| 8 | Bluetooth off during sleep (`bluetooth-sleep`) | `IOBluetooth` power state on sleep/wake notifications | Bluetooth | 13 | planned |

Not taken on: anything that duplicates the core (Vorssaint's keep-awake and lid toggle are what
Trinetra already does, with agent awareness and a dead-man switch).

## Done criteria per module

1. Off by default; switching it off stops every timer, tap and observer it started.
2. Permission asked only when switched on, with the reason in the menu.
3. Pure logic unit tested in `TrinetraCoreTests`; CI (`swift test` + unsigned `xcodebuild`) green.
4. LLD section added; README feature table updated.
