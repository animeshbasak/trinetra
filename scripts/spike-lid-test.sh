#!/usr/bin/env bash
# Sprint 0 · step 2 — does `pmset -a disablesleep 1` keep THIS Mac awake with the lid closed?
# Usage: scripts/spike-lid-test.sh [minutes=10]
# Run once on the power adapter and once on battery, with no external display.
# Always restores `disablesleep 0` on exit, even on Ctrl-C.
set -euo pipefail
MINUTES="${1:-10}"
LOG="$HOME/trinetra-spike-$(date +%Y%m%d-%H%M%S).log"

echo "This needs your admin password once (sudo)."
sudo -v
# Keep the sudo timestamp fresh so the restore at the end never waits on a prompt.
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
KEEPALIVE=$!

restore() {
  sudo pmset -a disablesleep 0 >/dev/null 2>&1 || true
  kill "$KEEPALIVE" 2>/dev/null || true
  echo "Restored. SleepDisabled = $(pmset -g | awk '/SleepDisabled/ {print $2}')"
}
trap restore EXIT INT TERM

sudo pmset -a disablesleep 1
echo "# $(pmset -g batt | head -1)" | tee "$LOG"
echo "Close the lid NOW and leave it for $MINUTES min. Ticking every 15 s → $LOG"

end=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  lid=$(ioreg -r -k AppleClamshellState -d 4 | awk '/AppleClamshellState/ {print $NF; exit}')
  batt=$(pmset -g batt | grep -Eo '[0-9]+%' | head -1)
  echo "$(date +%s) $(date +%H:%M:%S) lid=$lid batt=$batt" >> "$LOG"
  sleep 15
done

echo
grep -E '^[0-9]+ ' "$LOG" | awk '
  NR > 1 && $1 - prev > 30 { printf "GAP %ds before %s\n", $1 - prev, $2; gaps++ }
  /lid=Yes/ { closed++ }
  { prev = $1 }
  END {
    if (!closed) print "WARN: lid never reported closed — close it during the test";
    if (gaps) print "FAIL: the Mac slept"; else print "PASS: no gaps over 30 s";
  }'
