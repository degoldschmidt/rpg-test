#!/usr/bin/env bash
# Runs the gameplay test suite in parallel, one Godot process per test group.
#   tests/run.sh [quick|full] [group ...]
# GODOT=/path/to/godot overrides the binary (default: `godot` on PATH).
# Exits non-zero if any group fails or crashes.
set -u
cd "$(dirname "$0")/.."
SUITE="${1:-full}"
shift || true
GODOT="${GODOT:-godot}"
GROUPS_ALL=(core movement terrain objects combat)
GROUPS_SEL=("${@:-${GROUPS_ALL[@]}}")
if [ "$#" -eq 0 ]; then GROUPS_SEL=("${GROUPS_ALL[@]}"); fi
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
LOGDIR="$(mktemp -d)"

"$GODOT" --headless --path . --import >/dev/null 2>&1

start=$(date +%s)
pids=()
running=0
for g in "${GROUPS_SEL[@]}"; do
  ( timeout 1500 "$GODOT" --headless --fixed-fps 120 --path . -s tests/run_tests.gd -- \
      "--suite=$SUITE" "--group=$g" >"$LOGDIR/$g.log" 2>&1; echo $? >"$LOGDIR/$g.code" ) &
  pids+=($!)
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait

status=0
printf "\n%-10s %-8s %s\n" GROUP RESULT SUMMARY
for g in "${GROUPS_SEL[@]}"; do
  code=$(cat "$LOGDIR/$g.code" 2>/dev/null || echo 99)
  summary=$(grep -E "^==== " "$LOGDIR/$g.log" | tail -1)
  errors=$(grep -cE "^SCRIPT ERROR|^ERROR" "$LOGDIR/$g.log")
  result=ok
  if [ "$code" != "0" ] || [ -z "$summary" ] || [ "$errors" != "0" ]; then result=FAIL; status=1; fi
  printf "%-10s %-8s %s%s\n" "$g" "$result" "${summary:-<no summary, exit $code>}" \
    "$( [ "$errors" != "0" ] && echo "  ($errors engine/script errors)")"
  if [ "$result" = FAIL ]; then
    grep -E "FAIL|SCRIPT ERROR|^ERROR" "$LOGDIR/$g.log" | head -20 | sed 's/^/    /'
  fi
done
echo "Total wall time: $(( $(date +%s) - start )) s  (suite: $SUITE, jobs: $JOBS, logs: $LOGDIR)"
exit $status
