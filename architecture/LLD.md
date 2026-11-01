# Trinetra — Low Level Design

**Version:** v0.2 · covers Sprint 0 + Sprint 1 in full, interfaces for Sprints 2–3
**Author:** Animesh Basak
**Date:** 31 Oct 2026
**Status:** Draft → Review → Approved
**Read with:** `architecture/HLD.md`

---

## 1. File Structure

```
trinetra/
├── CLAUDE.md                         Build prompt + rules for Claude Code
├── README.md · LICENSE (MIT) · .gitignore
├── project.yml                       XcodeGen spec: Trinetra.app + TrinetraHelper
├── architecture/HLD.md · LLD.md
├── Assets/icon/                      Source SVGs + rendered PNGs + preview.png
├── scripts/
│   ├── spike-env.sh                  Sprint 0: versions, power, clamshell
│   ├── spike-lid-test.sh             Sprint 0: timed disablesleep lid test (sudo)
│   └── install-cli.sh                Build trinetra CLI → ~/.local/bin/trinetra
├── Packages/TrinetraCore/               SwiftPM: all logic, testable with `swift test`
│   ├── Package.swift
│   ├── Sources/TrinetraCore/
│   │   ├── Paths.swift               App Support / sessions / control / settings paths
│   │   ├── SessionRecord.swift       Codable session file model + AgentState
│   │   ├── SessionStore.swift        Atomic read/write/prune of session files
│   │   ├── ControlState.swift        timer / stop requests written by CLI + Telegram
│   │   ├── Settings.swift            User settings with defaults
│   │   ├── PowerState.swift          AC / battery / thermal snapshot
│   │   ├── Reconciler.swift          Pure decision function (the heart)
│   │   ├── ProcessRules.swift        argv → remote/hold match (pure)
│   │   ├── HookInstaller.swift       Merge/unmerge Claude Code hooks JSON (pure)
│   │   ├── Duration.swift            "30m" / "2h" / "1h30m" parser + formatter
│   │   └── HelperProtocol.swift      @objc XPC protocol (Darwin only)
│   ├── Sources/trinetra/main.swift      CLI
│   ├── Sources/trinetra/Proc.swift      pid liveness + ancestor lookup (Darwin)
│   └── Tests/TrinetraCoreTests/         Reconciler, ProcessRules, HookInstaller,
│                                     SessionStore, Duration tests
├── App/                              Trinetra.app (menu bar)
│   ├── TrinetraApp.swift                @main, MenuBarExtra
│   ├── AppModel.swift                Poll → reconcile → apply; published UI state
│   ├── MenuContent.swift             Menu UI
│   ├── PowerAssertion.swift          IOPM idle-sleep assertion wrapper
│   ├── PowerMonitor.swift            IOPS battery/AC + thermal snapshot
│   ├── Trinetra.entitlements            Non-sandboxed, hardened runtime
│   └── Assets.xcassets/              AppIcon + MenuBarIdle/Awake/Lid/Alert (template)
└── Helper/                           Sprint 2 — root LaunchDaemon
    ├── main.swift                    NSXPCListener, dead-man switch, fixed pmset argv
    └── com.insanemesh.trinetra.helper.plist   SMAppService daemon plist
```

Bundle ids: app `com.insanemesh.trinetra`, helper `com.insanemesh.trinetra.helper` (also the Mach service name).

---

## 2. On-disk State (no database)

Base dir: `$TRINETRA_HOME` if set (tests), else `~/Library/Application Support/Trinetra/` (created `0700`).

| Path | Writer | Reader | Shape |
|---|---|---|---|
| `sessions/<agent>-<id>.json` | CLI (`hook`, `run`) | App | `SessionRecord` |
| `control.json` | CLI, App (Telegram, menu) | App | `ControlState` |
| `settings.json` | App (Settings UI) | App, CLI | `Settings` |
| `journal.json` | App (Sprint 2) | App, recovery | `[JournalEntry]` |

### SessionRecord

```swift
enum AgentState: String, Codable { case working, waiting, idle, ended }

struct SessionRecord: Codable, Equatable {
    var agent: String          // "claude" | "codex" | "gemini" | "run"
    var id: String             // agent session id, or "run-<pid>"
    var state: AgentState
    var pid: Int32             // process to watch for liveness (agent or wrapped child)
    var cwd: String?           // basename only is ever displayed/logged
    var startedAt: Date
    var updatedAt: Date
    var lastActiveAt: Date?    // last time state was working/waiting (grace basis)
}
```

Encoding: ISO-8601 dates, sorted keys, written atomically (`.atomic`), file mode `0600`.
Prune: delete records with `state == .ended` or dead pid whose `updatedAt` is older than 24 h.

### ControlState

```swift
struct ControlState: Codable, Equatable {
    var timerEnd: Date?        // manual keep-awake until
    var stopAt: Date?          // "stop now": ignore activity with lastActiveAt <= stopAt
    var ignoredPIDs: [Int32]   // remote-hold pids snapshotted by the app at stop time
}
```

### Settings (defaults)

| Key | Default | Meaning |
|---|---|---|
| `graceSeconds` | 180 | Stay awake after last activity |
| `waitingTimeoutSeconds` | 1800 | `waiting` counts as active for at most this long |
| `staleWorkingSeconds` | 14400 | `working` with no update for this long is ignored |
| `maxHoldSeconds` | 43200 | Absolute cap on one continuous hold |
| `batteryEndPercent` | 10 | Safety trip on battery at/below |
| `batteryLowPowerPercent` | 40 | Low Power Mode on battery at/below |
| `lidClosedMode` | true | Use helper to keep awake with lid closed |
| `allowBatteryLid` | true | Lid mode on battery (guarded by floor) |
| `processRules` | see §6 | Remote / hold rules |

---

## 3. CLI — `trinetra`

Installed to `~/.local/bin/trinetra` by `scripts/install-cli.sh` (later also embedded in `Trinetra.app/Contents/MacOS/trinetra`).

| Command | Effect | Exit |
|---|---|---|
| `trinetra hook <agent> <state>` | Reads hook JSON on stdin (`session_id`, `cwd`), resolves agent pid (§7), upserts `sessions/<agent>-<id>.json`. `state` ∈ working/waiting/idle/ended. Never blocks the agent: all errors → stderr, exit 0. | 0 always |
| `trinetra run -- <cmd> [args…]` | Spawns cmd, writes `run-<childpid>` as working, waits, marks ended, propagates exit code; forwards SIGINT/SIGTERM. | child's code |
| `trinetra start <dur>` | `timerEnd = now + dur`; clears `stopAt` | 0 |
| `trinetra extend <dur>` | `timerEnd = max(now, timerEnd) + dur` | 0 |
| `trinetra stop` | `timerEnd = nil`, `stopAt = now` | 0 |
| `trinetra status [--json]` | Prints live sessions, timer, and what the reconciler would decide (power unknown → assumes AC) | 0 |
| `trinetra hooks install claude [--bin <path>]` | Backs up `~/.claude/settings.json` → `.trinetra.bak` (first time only), merges hooks (§5) | 0 / 1 |
| `trinetra hooks uninstall claude` | Removes only Trinetra entries | 0 / 1 |

Durations: `90s`, `30m`, `2h`, `1h30m`, `1d`. Invalid → exit 2 with usage.

---

## 4. Reconciler (TrinetraCore/Reconciler.swift)

```swift
struct ReconcileInput {
    var now: Date
    var sessions: [SessionRecord]
    var remotePIDs: [Int32]          // from ProcessWatcher (Sprint 2); [] in Sprint 1
    var control: ControlState
    var power: PowerState            // onAC, batteryPercent?, thermal
    var settings: Settings
    var holdStartedAt: Date?         // app-tracked start of current continuous hold
    var isAlive: (Int32) -> Bool
}

enum SafetyTrip: String { case thermalCritical, batteryFloor, maxHold }

struct Decision: Equatable {
    var awake: Bool
    var lidMode: Bool
    var lowPower: Bool
    var trip: SafetyTrip?
    var reasons: [String]            // human-readable, shown in menu
    var activeSessions: [SessionRecord]
}

enum Reconciler { static func decide(_ input: ReconcileInput) -> Decision }
```

Rules (in order):
1. Session counts as **active** if alive, not ignored by `stopAt`, and
   `working` with `now - updatedAt < staleWorkingSeconds`, or
   `waiting` with `now - updatedAt < waitingTimeoutSeconds`.
2. **Grace:** any session (not ignored) with `lastActiveAt + graceSeconds > now`.
3. **Remote holds:** `remotePIDs` alive and not in `ignoredPIDs`.
4. **Timer:** `timerEnd > now`.
5. `wantAwake = active ∪ remote ≠ ∅ || grace || timer`.
6. **Trip** (first match): thermal critical → `batteryFloor` if on battery and `battery ≤ batteryEndPercent` → `maxHold` if `holdStartedAt` and `now - holdStartedAt ≥ maxHoldSeconds`.
7. `awake = wantAwake && trip == nil`; `lidMode = awake && lidClosedMode && (onAC || allowBatteryLid)`; `lowPower = awake && ((!onAC && battery ≤ batteryLowPowerPercent) || thermal ≥ .serious)`.

Pure: no I/O, no clock, no globals. Every rule has a test.

---

## 5. Claude Code hook integration

Merged into `~/.claude/settings.json` → `hooks`. Each Trinetra command contains the marker `trinetra hook ` so uninstall can find it. Existing entries are preserved untouched.

| Event | Matcher | Command |
|---|---|---|
| `SessionStart` | – | `<bin> hook claude idle` |
| `UserPromptSubmit` | – | `<bin> hook claude working` |
| `PreToolUse` | `*` | `<bin> hook claude working` (keeps long turns fresh) |
| `Notification` | `permission_prompt` | `<bin> hook claude waiting` |
| `Notification` | `idle_prompt` | `<bin> hook claude idle` |
| `Stop` | – | `<bin> hook claude idle` |
| `SessionEnd` | – | `<bin> hook claude ended` |

Each entry: `{"type":"command","command":"…","timeout":5}`. Shape:

```json
{ "hooks": { "Notification": [ { "matcher": "permission_prompt",
    "hooks": [ { "type": "command", "command": "/Users/x/.local/bin/trinetra hook claude waiting", "timeout": 5 } ] } ] } }
```

Codex (`~/.codex/config.toml`) and Gemini (`~/.gemini/settings.json`) adapters: Sprint 3, same `trinetra hook <agent> <state>` contract.

---

## 6. Process rules (TrinetraCore/ProcessRules.swift)

```swift
struct ProcessRule: Codable, Equatable {
    enum Kind: String, Codable { case remote, hold }
    var name: String
    var executable: String          // basename match, e.g. "claude"
    var argsContainAny: [String]    // empty = any args
    var kind: Kind
}
```

Defaults: `claude-remote` → executable `claude`, args any of `--remote-control`, `--rc`, `remote-control`, kind `remote`.
Others (Codex/ChatGPT remote, pm2 jobs, Cursor) are user-added in Settings once their argv is confirmed — no guessed defaults.
`ProcessRules.match(executablePath:args:rules:) -> ProcessRule?` is pure. The Darwin scanner (Sprint 2, `App/ProcessWatcher.swift`) lists pids with `proc_listallpids`, reads argv via `sysctl(KERN_PROCARGS2)`, calls `match`.

---

## 7. Agent pid resolution (CLI, Darwin)

Claude runs hooks via a shell, so `getppid()` may be a short-lived `sh`. Walk up to 4 ancestors with `sysctl(KERN_PROC_PID)` → `kp_eproc.e_ppid`, read each name with `proc_name`; take the first named `claude` or `node`. Fallback: `getppid()`. Liveness: `kill(pid, 0) == 0 || errno == EPERM`.

---

## 8. App (Sprint 1)

- `AppModel` (`@MainActor`, `ObservableObject`): 3 s timer → load sessions/control/settings → `PowerMonitor.snapshot()` → `Reconciler.decide` → apply. Tracks `holdStartedAt` (set on awake false→true, cleared on true→false).
- Trips are sticky: when a new trip appears the app writes `control.stop(now)`, so the hold only resumes on fresh activity (avoids flapping when heat or `holdStartedAt` resets).
- Apply: `PowerAssertion.set(active: decision.awake, reason:)`. Lid mode and low power are **displayed only** in Sprint 1 (helper wiring is Sprint 2).
- Icon: `idle` (not awake), `awake`, `lid` (awake && lidMode && helper connected — Sprint 2), `alert` (trip != nil).
- Animated eye (`App/EyeAnimator.swift`, frames `MenuBarEye0`…`4`): opens when a hold starts, blinks every 6–12 s while holding, closes when it ends, one blink on timer extend; static `MenuBarAlert` on a trip or error; Reduce Motion → no animation. Menu shows "keep the lid open" until the helper holds `disablesleep`.
- Menu: status line, reasons, active sessions (agent · cwd basename · state · age), timer buttons 30m / 1h / 2h / 4h, Stop, Install Claude hooks, Open logs, Quit.
- `LSUIElement = YES` (no Dock icon). Non-sandboxed (needs to read other processes and its own App Support).

---

## 9. Helper (Sprint 2)

```swift
@objc protocol TrinetraHelperProtocol {
    func setLidSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func heartbeat(reply: @escaping () -> Void)
    func state(reply: @escaping (_ lidSleepDisabled: Bool, _ lowPower: Bool) -> Void)
}
```

- Executes only `/usr/bin/pmset` with argv `["-a","disablesleep","0|1"]` or `["-b","lowpowermode","0|1"]`.
- On launch: `disablesleep 0`, `lowpowermode 0`.
- Dead-man: 10 s check; if `disablesleep` set and last heartbeat > 120 s → revert both.
- XPC: `listener.setConnectionCodeSigningRequirement` / per-connection `setCodeSigningRequirement` with `identifier "com.insanemesh.trinetra" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` (Personal Team id from Sprint 0).
- Register: `SMAppService.daemon(plistName: "com.insanemesh.trinetra.helper.plist").register()`; user approves once in System Settings → Login Items. Fallback script if Sprint 0 shows Personal Team can't register.

---

## 10. Environment / Config

No env vars required. Optional: `TRINETRA_HOME` (override state dir; tests and dev). Telegram (Sprint 3): bot token + chat id in login Keychain service `com.insanemesh.trinetra.telegram`.

---

## 11. Error Handling Map

| Scenario | Behaviour | User sees | Logged |
|---|---|---|---|
| Hook can't parse stdin | Use `id = "unknown-<ppid>"` | Nothing (agent never blocked) | stderr |
| State dir unwritable | CLI exit 0 (hook) / 1 (others) | CLI error message | stderr |
| Corrupt session file | Skip file | Nothing | app log |
| Assertion create fails | Retry next tick | Menu: "Couldn't hold awake" + alert icon | app log |
| Battery floor reached | Release hold | Alert icon + notification | app log |
| Helper not registered (S2) | Idle-only mode | Menu: "Lid mode unavailable" | app log |
| `settings.json` invalid | Use defaults, keep file | Menu banner | app log |

---

## 12. Done Criteria

**Sprint 0**
- [ ] `scripts/spike-env.sh` output pasted into HLD §12
- [ ] `scripts/spike-lid-test.sh 10` run lid-closed on AC and on battery; log shows no gap > 30 s
- [ ] SMAppService Personal-Team registration attempted; result recorded

**Sprint 1**
- [ ] `cd Packages/TrinetraCore && swift test` green (all Reconciler rules covered)
- [ ] `scripts/install-cli.sh` installs `~/.local/bin/trinetra`; `trinetra status` works
- [ ] `trinetra hooks install claude` merges without touching existing hooks; `uninstall` restores
- [ ] `xcodegen && xcodebuild -scheme Trinetra build` succeeds; app shows third-eye icon in menu bar
- [ ] During a Claude Code turn: `pmset -g assertions` lists Trinetra's `PreventUserIdleSystemSleep`
- [ ] 3 min after `Stop`, the assertion is gone
- [ ] `trinetra start 30m` holds; `trinetra stop` releases within one tick

---

## 13. Lid mode through the helper (1 Nov 2026)

- Menu toggle **Keep awake with the lid closed** (`lidModeOn`, UserDefaults). Turning it on registers `TrinetraHelper` with `SMAppService.daemon`; the user approves it once in System Settings › General › Login Items. No password per hold, no sudoers rule, no scripts.
- `LidGuard` (App) talks to the helper over a privileged XPC connection: `setLidSleepDisabled(true)` when a hold starts and lid mode is wanted, `false` when it ends, a heartbeat every ~30 s.
- The helper runs only `/usr/bin/pmset -a disablesleep 0|1` (fixed argv), accepts only `com.insanemesh.trinetra` signed by team `KNBZ4G3K97`, and restores `0` when the app's connection is invalidated or interrupted, after 120 s without a heartbeat, and on every launch (it runs at boot).
- The temporary admin-prompt guard script from 31 Oct is gone.
- Agent rows: `SessionRecord.activity` (from `ActivitySummary`: tool + file name or the command's first word only, never prompt text) and `turnStartedAt` power the menu's "Agents" list (state dot, project, activity, elapsed).
