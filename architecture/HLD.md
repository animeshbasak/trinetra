# Trinetra — High Level Design

**Version:** v0.2 (remote-first scope) · supersedes v0.1 draft of 31 Oct 2026
**Author:** Animesh Basak
**Date:** 31 Oct 2026
**Status:** Draft → Review → Approved
**Name:** Trinetra (renamed from Vigil, 1 Nov 2026) · app `Trinetra.app` · CLI `trinetra` · icon: vertical third eye
**Licence / model:** MIT, free, open source · GitHub Sponsors later · no telemetry

---

## 1. Purpose

**Remote Control only works while your Mac is awake. Trinetra keeps it awake.**

Claude Code Remote Control and ChatGPT/Codex already let Animesh drive agents and approve permissions from his phone. All of that breaks the moment the MacBook sleeps: lid closed, idle timer, or a long gap between prompts sent from the phone. Trinetra keeps the Mac awake (including lid closed, no external display) exactly while agent work or a remote session needs it, puts it back to normal sleep afterwards, and pings his phone about the things agent apps can't see: battery, heat, Wi-Fi, and when the hold ends.

**User (v0.1):** Animesh only, Apple Silicon MacBook Pro. Agents: Claude Code (incl. Remote Control), Codex / ChatGPT, Gemini CLI, Cursor, Antigravity, plus pm2 / Ollama / PAARTH-Trader jobs.

---

## 2. Landscape (researched 31 Oct 2026)

| Tool | What it does well | Gap Trinetra fills |
|---|---|---|
| **Adrafinil** (521★, MIT, notarized) | Hooks for 10 agents, root helper, thermal cutout, lid-open summary, CLI + MCP | No phone alerts or remote extend/stop; holds are per turn, so an idle remote session sleeps |
| **krishhgg/Insomnia** (1.7k★) | Timed sessions, lid-close actions, battery and heat rules, hotspot handoff | Timer only (no agent awareness); sudoers rule usable by any process |
| **phin/insomnia** | Agent-aware via hooks | Leaves `disablesleep 1` on permanently; no safety rules |
| **Sleepless, Smart NoSleep, Lidless** | Lid-closed toggles, battery floor | Not agent-aware or not remote-aware |
| **Claude Code Remote Control / ChatGPT** | Approve, prompt and watch agents from phone | Can't stop the Mac sleeping; don't know battery, heat or Wi-Fi state |

**Trinetra's one-liner:** *Keeps your Mac awake for remote-controlled agents, lid closed, and tells your phone when the Mac itself needs attention.*

**Differentiators (the reason to exist — keep these sharp):**
1. **Remote hold:** stays awake while a remote-control session is *open*, not just while a turn runs, so prompts sent from the phone an hour later still land.
2. **Mac-health alerts to phone:** battery floor approaching, thermal throttling, Wi-Fi lost/restored, hold ended, safety trip.
3. **Remote extend / stop** from Telegram.
4. **Hybrid sessions:** agent-aware + manual timer + `trinetra run -- <cmd>` for any process.
5. **Safe by construction:** single-purpose root helper (no sudoers), dead-man switch, battery floor mandatory because `disablesleep` also disables macOS's own low-battery sleep.

**Explicitly not building:** permission approvals, chat or prompt relay over Telegram. Claude and ChatGPT already do that.

**Toolkit (added 4 Nov 2026):** beside the core, Trinetra grows optional modules covering a full Mac menu bar toolkit (system monitor, alerts, files and clipboard, windows, sound, everyday tools, capture, maintenance, hardware). All off by default, our own MIT code, phased in [TOOLKIT.md](TOOLKIT.md). The keep-awake core never depends on a module.

---

## 3. System Overview

```
 ┌──────────── agent hooks ────────────┐  ┌── process rules ──┐  ┌─ any process ─┐
 │ Claude Code │ Codex │ Gemini CLI    │  │ claude --rc,      │  │ trinetra run --  │
 │ (turn + session events)             │  │ codex, Cursor,    │  │   <cmd>       │
 └─────────────┬───────────────────────┘  │ Antigravity, pm2  │  └──────┬────────┘
               │ trinetra hook <agent>       └────────┬──────────┘         │
               ▼                                   │ argv scan (5 s)    │ child pid
   ~/Library/Application Support/Trinetra/            │                    │
     sessions/<agent>-<id>.json  ◀─────────────────┼────────────────────┘
     control.json (timer, extend, stop)            │
               │ FSEvents + 5 s tick               │
               ▼                                   ▼
 ┌──────────────────────────── Trinetra.app (menu bar, unprivileged) ─────────────────────────┐
 │ Inputs                         Reconciler (pure, TrinetraCore)       Effectors              │
 │ • SessionStore                 desired = {awake, lidMode,          • IOPM idle assertion  │
 │ • ProcessWatcher (remote/IDE) ─▶ lowPower, reasons, trip} ─diff─▶ • Helper XPC client    │
 │ • Control (timer/extend/stop)                                     • Lid-close actions    │
 │ • Power / Thermal / Lid / Wi-Fi                                    • Telegram notifier    │
 │ RecoveryJournal · Telegram long-poll (/status /extend /stop) · lid-open summary          │
 └───────────────────────────┬─────────────────────────────────────────────────────────────┘
                             │ XPC Mach service, peer code-signing requirement enforced
                             ▼
 ┌──────────────── TrinetraHelper (root LaunchDaemon) ───────────────────────────────────────┐
 │ setLidSleepDisabled(Bool) · setLowPowerMode(Bool) · heartbeat() · state()              │
 │ Runs only fixed argv: /usr/bin/pmset -a disablesleep 0|1, pmset -b lowpowermode 0|1    │
 │ Dead-man: no heartbeat for 120 s → disablesleep 0 + lowpowermode 0. Reset on launch.   │
 └────────────────────────────────────────────────────────────────────────────────────────┘
 Remote: Telegram Bot API ⇄ Trinetra.app (outbound HTTPS long-poll only; no server)
```

---

## 4. Key Design Decisions

| Decision | Choice | Why | Trade-off |
|---|---|---|---|
| Session model | Hybrid: agent turns + remote hold + timer + wrapped processes | Matches how remote agents are actually used | More inputs to reconcile (kept in one pure function) |
| Remote hold | Detect remote sessions from process argv (`claude --remote-control`/`--rc`/`remote-control`, configurable patterns for Codex etc.) and hold while the process lives | Remote sessions idle between phone prompts; per-turn holds would let the Mac sleep | Argv matching is heuristic; patterns are user-editable |
| Idle sleep | `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` in the app | No privileges; dies with the process | Doesn't cover lid close |
| Lid-closed sleep | `pmset -a disablesleep 1` run by root helper only during a hold | Only reliable lid-closed override on Apple Silicon; confirmed working on battery on macOS 26.3 (Sleepless) | Needs a privileged component |
| Battery floor | **Mandatory**, default end at 10 %, Low Power Mode at 40 % | `disablesleep` also disables macOS's low-battery sleep (Smart NoSleep finding) | Floor only enforced while app runs; helper dead-man covers crashes |
| Privilege model | SMAppService LaunchDaemon + XPC, peer requirement check | No sudoers, no shell, nothing else can call it | SMAppService wants a team ID → Sprint 0 tests free Personal Team; **fallback** `scripts/install-helper.sh` installs the LaunchDaemon manually (same binary, same XPC check) |
| Revert guarantee | Helper dead-man switch + reset-on-launch + app write-ahead journal | Crash, force-quit or reboot never leaves lid sleep off | Two recovery owners, each tiny |
| Remote channel | Telegram bot, long-poll from Mac; alerts + `/status` `/extend` `/stop` only | Two-way, free, NAT-friendly, no server | Needs network while lid closed (that's also an alert) |
| Build | SwiftPM package `TrinetraCore` (logic + CLI, unit-tested) + XcodeGen `project.yml` for app + helper | Engine testable with `swift test`; Xcode only for bundling/signing | XcodeGen dependency |
| UI | SwiftUI `MenuBarExtra`, template icons (idle / awake / lid / alert) | Native, no Dock icon | macOS 13+ |
| Distribution | v0.1 personal build; v1.0 Developer ID + notarized DMG + Homebrew cask | Root helper needs trust; notarization removes Gatekeeper friction | $99/yr Apple Developer Program at v1.0 |

---

## 5. Data Flow — primary use case (remote session, lid closed)

1. Animesh runs `claude --rc` in `~/Projects/foo`, connects from the Claude app on his phone. ProcessWatcher sees the argv → **remote hold** for that pid.
2. Reconciler → awake + lidMode (on AC, or battery above floor). App takes the idle assertion, journals, calls `helper.setLidSleepDisabled(true)`, heartbeats every 30 s. Telegram: `👁 Holding awake: Claude remote session (foo). Battery 82 %.`
3. He closes the lid and leaves. Lid-close actions: display/keyboard off, freeze Slack/WhatsApp/Discord, mute, Low Power Mode if on battery.
4. He sends prompts from the phone over the next 2 h. Turn hooks mark working/idle; the remote hold keeps the Mac awake between turns.
5. Battery hits 25 % → Telegram `🔋 25 %: hold ends at 10 %. [+30m] [Stop]`. Wi-Fi drops → alert queued, sent on reconnect with offline duration.
6. He ends the session (or the process exits) → grace 3 min → release assertion, `setLidSleepDisabled(false)`, unfreeze, unmute. Telegram: `💤 Hold ended after 2 h 14 m. Peak thermal: fair.`
7. Lid opens → summary notification.

**Failure path:** app crashes → heartbeats stop → helper runs `disablesleep 0` within 120 s → Mac sleeps normally. Next launch replays the journal (unfreeze recorded pids, restore audio).

---

## 6. Reconcile rule (pure, in TrinetraCore)

```
activeTurns  = sessions where state ∈ {working, waiting} && pidAlive && !stale
remoteHolds  = processes matching remote patterns && alive
inGrace      = now < lastActiveAt + grace                (default 180 s)
timerOn      = control.timerEnd > now
wantAwake    = (activeTurns ∪ remoteHolds ∪ wrapped ∪ ideBusy).nonEmpty || inGrace || timerOn
safetyTrip   = thermal == critical
            || (onBattery && battery ≤ endFloor)          (default 10 %)
            || holdAge > maxHold                          (default 12 h)
            || control.stopRequested
awake        = wantAwake && !safetyTrip
lidMode      = awake && settings.lidClosedMode && (onAC || settings.allowBatteryLid)
lowPower     = awake && ((onBattery && battery ≤ lowPowerAt) || thermal ≥ serious)
```

---

## 7. External Dependencies

| Dependency | Purpose | If unavailable |
|---|---|---|
| IOKit power management | Assertions, power source, thermal | Core; app shows error and does nothing |
| `/usr/bin/pmset` (via helper) | disablesleep, lowpowermode | Idle-only mode; menu shows "Lid mode unavailable" |
| SMAppService (macOS 13+) | Register helper | Manual LaunchDaemon install script |
| Agent hooks | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.gemini/settings.json` | Agent not tracked; process rules + `trinetra run` still work |
| Telegram Bot API | Alerts + 3 commands | Local notifications; retry with backoff |

---

## 8. Security Considerations

- **Helper:** 4 methods, Bool args, fixed `pmset` argv, no shell, no paths. XPC listener enforces the app's code-signing requirement (bundle id + team id, or cdhash for local builds).
- **No sudoers rule.** No passwordless `pmset` for the user account.
- **Always revert:** dead-man (120 s) + `disablesleep 0` on every helper start.
- **Telegram:** token in login Keychain; accept updates only from the configured `chat_id`; commands limited to status / extend / stop. No shell, no prompt relay.
- **Hook installs:** back up `<config>.trinetra.bak`, merge entries tagged with `trinetra hook`, uninstall removes only those.
- **Freezing:** unfreeze only pids Trinetra recorded (pid + start time).
- **Logs:** `~/Library/Logs/Trinetra/`, owner-only; agent name, cwd basename, event, timestamps. No prompt text.

---

## 9. Sprint Plan

| Sprint | Scope | Done when |
|---|---|---|
| **0 — Spike (½ day)** | `scripts/spike-env.sh` + `scripts/spike-lid-test.sh` on Animesh's Mac: macOS version, Xcode/Swift, `disablesleep` lid-closed on AC **and** battery, clamshell read; SMAppService registration with Personal Team | 4 answers recorded in §12 |
| **1 — Core** | TrinetraCore reconciler + tests, session store, `trinetra` CLI (`hook`, `run`, `start`, `stop`, `extend`, `status`, `hooks install/uninstall claude`), menu bar app with idle assertion + icons | Mac stays awake during a Claude Code turn and sleeps 3 min after; `swift test` green |
| **2 — Lid + safety** | Helper + XPC + dead-man, journal + recovery, power/thermal/battery rules, lid-close actions, remote hold via ProcessWatcher, lid-open summary | Lid-closed `claude --rc` session survives 1 h on AC; force-quit restores lid sleep < 2 min |
| **3 — Phone + coverage** | Telegram alerts + `/status` `/extend` `/stop`, Wi-Fi monitor, Codex + Gemini hooks, IDE/process rules editor, Settings window, launch at login | Phone gets battery/heat/Wi-Fi/hold-ended alerts and can extend/stop |
| **v1.0 — Public** | Developer ID signing, notarized DMG, Homebrew cask, README GIF, SECURITY.md + threat model, GitHub Sponsors | Clean install on a second Mac; Show HN |

---

## 10. Out of Scope (v0.1)

Permission approvals or prompt relay · notarization · auto-update · Intel · multi-user · Docker freezing · hotspot handoff · tmux nudges · any backend.

---

## 11. Open Questions

1. macOS version → deployment target (spike answers this).
2. ~~Final name~~ Decided: **Trinetra** (repo github.com/animeshbasak/trinetra).
3. Default `allowBatteryLid`: proposed **on**, guarded by the mandatory floor.

---

## 12. Spike Results (fill in Sprint 0)

| Question | Answer |
|---|---|
| macOS / Xcode / Swift versions | macOS 27.0 (26A428), Apple M5 Pro (Mac17,8), Xcode 27.1, Swift 6.4. XcodeGen not installed (2026-10-31) |
| `disablesleep 1` keeps Mac awake lid-closed on AC (10 min) | |
| Same on battery, no display (10 min) | |
| Signing identity | Personal Team (free) `KNBZ4G3K97`; Apple Development certificate created 2026-10-31; signed Debug build succeeds. Free team cannot ship Developer ID / notarize. |
| Assertion-only hold vs lid close (informal, 31 Oct 17:38) | **Does not survive.** With Trinetra holding `PreventUserIdleSystemSleep`, closing the lid on battery (50 %), no display, slept the Mac; it woke when the lid opened (17:39:50). Log line read "Maintenance Sleep", not "Clamshell Sleep", so the real sleep may have started earlier. Confirms the helper (`disablesleep`) is required for lid mode, not optional. |
| SMAppService daemon registers with Personal Team signing | |
