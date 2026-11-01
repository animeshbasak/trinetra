#!/usr/bin/env bash
# Sprint 0 · step 1 — read-only facts about this Mac. Paste the output into architecture/HLD.md §12.
set -uo pipefail
echo "## Trinetra spike — environment ($(date '+%Y-%m-%d %H:%M'))"
echo "macOS:      $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Chip:       $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "Model:      $(sysctl -n hw.model)"
echo "Xcode:      $(xcodebuild -version 2>/dev/null | head -1 || echo 'not installed')"
echo "Swift:      $(swift --version 2>/dev/null | head -1 || echo 'not installed')"
echo "XcodeGen:   $(command -v xcodegen >/dev/null && xcodegen --version || echo 'not installed — brew install xcodegen')"
echo "Power:      $(pmset -g batt | head -1)"
echo "Battery:    $(pmset -g batt | grep -Eo '[0-9]+%' | head -1)"
echo "Lid:        AppleClamshellState=$(ioreg -r -k AppleClamshellState -d 4 | awk '/AppleClamshellState/ {print $NF; exit}')"
echo "SleepDisabled now: $(pmset -g | awk '/SleepDisabled/ {print $2}')  (should be 0 or empty)"
echo "Signing identities:"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /'
echo "Sleep-related assertions:"
pmset -g assertions | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep' | head -5 | sed 's/^/  /'
