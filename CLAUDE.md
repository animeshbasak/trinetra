# Trinetra — build instructions for Claude Code

Read `architecture/HLD.md` and `architecture/LLD.md` before changing anything. They are the spec. If code and spec disagree, stop and ask; update the spec in the same change when a decision changes.

## What this is

A macOS menu bar app (SwiftUI, macOS 13+) + `trinetra` CLI that keeps the Mac awake — lid closed included — while AI agents or remote-control sessions are working, then lets it sleep. Positioning: *Remote Control only works while your Mac is awake. Trinetra keeps it awake.* Open source, MIT, no telemetry.

## Layout

- `Packages/TrinetraCore/` — SwiftPM: all logic (`TrinetraCore`) + CLI (`trinetra`) + tests. Must stay testable with `swift test`, no AppKit.
- `App/` — Trinetra.app (menu bar). `Helper/` — root LaunchDaemon (Sprint 2). `project.yml` — XcodeGen.
- `Assets/icon/` — third-eye icon sources. `scripts/` — spike + install scripts.

## Status (1 Nov 2026)

Sprint 1 done, lid mode now runs through the SMAppService helper (LLD §13). Next: remote-session hold, Telegram alerts, Gemini hooks.

## Original sprint 0 → 1 notes

**Sprint 0 (needs the human for sudo + closing the lid):**
1. Run `scripts/spike-env.sh`; paste output into HLD §12.
2. Ask Animesh to run `scripts/spike-lid-test.sh 10` twice (on AC, then battery, no display). Record PASS/FAIL in HLD §12.
3. Record the Personal Team id from `security find-identity -v -p codesigning`.

**Sprint 1 (you):**
1. `cd Packages/TrinetraCore && swift build && swift test` — fix compile errors without weakening tests. The code was written without a compiler; expect small fixes.
2. `scripts/install-cli.sh`, then `trinetra status`.
3. `trinetra hooks install claude` — confirm `~/.claude/settings.json.trinetra.bak` exists and existing hooks survived.
4. `brew install xcodegen` if missing → set `DEVELOPMENT_TEAM` in `project.yml` → `xcodegen` → `xcodebuild -scheme Trinetra -configuration Debug build`.
5. Launch the app; verify the done criteria in LLD §12 (use `pmset -g assertions`).

## Rules

- **Never leave `disablesleep` set to 1.** Any code or script that sets it must restore it on every exit path.
- **No sudoers rules, ever.** Privilege goes only through the helper's 4 XPC methods with fixed `pmset` argv.
- The `Reconciler` stays a pure function. New behaviour = new input field + new test.
- Hooks must never block or fail an agent: `trinetra hook` always exits 0, fast.
- Don't edit `~/.claude/settings.json` by hand; use `trinetra hooks install|uninstall claude`.
- Log agent name, cwd basename, event and timestamps only. Never prompt text.
- No telemetry, no network calls except Telegram (Sprint 3).
- Swift: strict about optionals, no force-unwraps outside tests, no new dependencies without asking.
- Commit per sprint step with clear messages. Don't push or create the GitHub repo until Animesh says so.
