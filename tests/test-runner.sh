#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/reannounce-new.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fake-deluge-console"
CLOCK="$TMP/fake-clock"
HASH=0123456789abcdef0123456789abcdef01234567

cat > "$CLOCK" <<'CLOCK'
#!/usr/bin/env bash
n=0
[ ! -f "$CLOCK_STATE" ] || n=$(cat "$CLOCK_STATE")
n=$((n + 1))
printf '%s\n' "$n" > "$CLOCK_STATE"
printf '%s\n' "$n"
CLOCK
cat > "$FAKE" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_CALLS"
if [[ "$*" == *"info -v "* ]]; then
  n=0; [ ! -f "$MOCK_INFO_COUNT" ] || n=$(cat "$MOCK_INFO_COUNT")
  n=$((n + 1)); printf '%s\n' "$n" > "$MOCK_INFO_COUNT"
  state=$(cat "$MOCK_TORRENT_STATE_FILE")
  echo "State: $state"
  if [ -f "$MOCK_ANNOUNCED" ] || [ "$MOCK_MODE" = ok ] || { [ "$MOCK_MODE" = delayed ] && [ "$n" -ge 2 ]; }; then
    echo 'Tracker status: mock: Announce OK'
  elif [ "$MOCK_MODE" = sent ]; then
    echo 'Tracker status: mock: Announce Sent'
  elif [ "$MOCK_MODE" = delayed ]; then
    echo 'Tracker status: mock: Announce Sent'
  else
    echo 'Tracker status: mock: Tracker Error'
  fi
elif [[ "$*" == *"pause $MOCK_HASH" ]]; then
  n=0; [ ! -f "$MOCK_PAUSE_COUNT" ] || n=$(cat "$MOCK_PAUSE_COUNT")
  n=$((n + 1)); printf '%s\n' "$n" > "$MOCK_PAUSE_COUNT"
  if [ "${MOCK_FAIL_PAUSE_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ]; then
    echo 'mock pause failure' >&2; exit 1
  fi
  if [ "${MOCK_IGNORE_PAUSE:-0}" != 1 ]; then
    printf '%s\n' Paused > "$MOCK_TORRENT_STATE_FILE"
    : > "$MOCK_PAUSED_MARKER"
    echo pause >> "$MOCK_ACTIONS"
  fi
elif [[ "$*" == *"resume $MOCK_HASH" ]]; then
  n=0; [ ! -f "$MOCK_RESUME_COUNT" ] || n=$(cat "$MOCK_RESUME_COUNT")
  n=$((n + 1)); printf '%s\n' "$n" > "$MOCK_RESUME_COUNT"
  if [ "${MOCK_FAIL_RESUME_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ]; then
    echo 'mock resume failure' >&2; exit 1
  fi
  if [ "${MOCK_STUCK_RESUME_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ]; then
    echo resume >> "$MOCK_ACTIONS"
    exit 0
  fi
  was_paused=0; [ ! -f "$MOCK_PAUSED_MARKER" ] || was_paused=1
  rm -f "$MOCK_PAUSED_MARKER"
  printf '%s\n' Downloading > "$MOCK_TORRENT_STATE_FILE"
  echo resume >> "$MOCK_ACTIONS"
  if [ "$was_paused" -eq 1 ]; then : > "$MOCK_ANNOUNCED"; fi
else
  echo "unexpected mock command: $*" >&2; exit 90
fi
MOCK
chmod +x "$FAKE" "$CLOCK"

reset_case() {
  rm -f "$TMP/torrent-state" "$TMP/announced" "$TMP/actions" "$TMP/paused-marker" "$TMP/pause-count" "$TMP/resume-count" "$TMP/info-count" "$TMP/calls" "$TMP/clock-state" "$TMP/log"
  printf '%s\n' Downloading > "$TMP/torrent-state"
  export MOCK_HASH="$HASH" MOCK_MODE="$1"
  export MOCK_TORRENT_STATE_FILE="$TMP/torrent-state"
  export MOCK_ANNOUNCED="$TMP/announced" MOCK_ACTIONS="$TMP/actions" MOCK_PAUSED_MARKER="$TMP/paused-marker"
  export MOCK_PAUSE_COUNT="$TMP/pause-count" MOCK_RESUME_COUNT="$TMP/resume-count"
  export MOCK_INFO_COUNT="$TMP/info-count" MOCK_CALLS="$TMP/calls"
  export CLOCK_STATE="$TMP/clock-state"
}
run_runner() {
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/deluge-config" \
    DELUGE_PORT=58846 NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 \
    MAX_RUNTIME=300 REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
}
assert_no_direct_reannounce() {
  if grep -qE '(^|;[[:space:]]*)reannounce[[:space:]]' "$TMP/calls"; then
    echo 'runner invoked direct reannounce'; exit 1
  fi
}
run_case() {
  mode=$1; expected=$2
  reset_case "$mode"
  run_runner
  count=0; [ ! -f "$TMP/actions" ] || count=$(wc -l < "$TMP/actions")
  [ "$count" -eq "$((expected * 2))" ] || { echo "$mode: expected $((expected * 2)) actions, got $count"; exit 1; }
  if [ "$expected" -gt 0 ]; then
    [ "$(sed -n '1p' "$TMP/actions")" = pause ] || { echo "$mode: pause was not first"; exit 1; }
    [ "$(sed -n '2p' "$TMP/actions")" = resume ] || { echo "$mode: resume was not second"; exit 1; }
  fi
  grep -F -- "-c $TMP/deluge-config connect 127.0.0.1:58846;" "$TMP/calls" >/dev/null
  assert_no_direct_reannounce
}
run_paused_case() {
  reset_case error
  printf '%s\n' Paused > "$MOCK_TORRENT_STATE_FILE"
  run_runner
  [ ! -s "$TMP/actions" ] || { echo 'paused torrent was modified'; exit 1; }
  grep -q 'SKIPPED | Torrent was already paused' "$TMP/log"
}
run_failure_case() {
  failure=$1
  reset_case error
  if [ "$failure" = pause ]; then export MOCK_FAIL_PAUSE_ONCE=1; else export MOCK_FAIL_RESUME_ONCE=1; fi
  run_runner
  [ -s "$TMP/resume-count" ] || { echo "$failure: resume was not attempted"; exit 1; }
  if [ "$failure" = pause ]; then
    [ "$(cat "$TMP/pause-count")" -ge 2 ] || { echo 'pause failure was not retried'; exit 1; }
  else
    [ "$(cat "$TMP/pause-count")" -eq 1 ] || { echo 'pause repeated while recovering resume'; exit 1; }
    [ "$(cat "$TMP/resume-count")" -ge 2 ] || { echo 'resume recovery was not retried'; exit 1; }
  fi
  grep -q 'SUCCESS | Announce OK' "$TMP/log"
  unset MOCK_FAIL_PAUSE_ONCE MOCK_FAIL_RESUME_ONCE
}
run_stuck_resume_case() {
  reset_case error
  export MOCK_STUCK_RESUME_ONCE=1
  run_runner
  [ "$(cat "$TMP/pause-count")" -eq 1 ] || { echo 'pause repeated before resume recovery'; exit 1; }
  [ "$(cat "$TMP/resume-count")" -ge 2 ] || { echo 'zero-exit but ineffective resume was not retried'; exit 1; }
  grep -q 'RESUME_VERIFY_PENDING' "$TMP/log" || { echo 'ineffective resume was not detected'; exit 1; }
  grep -q 'RESUME_RECOVERED' "$TMP/log" || { echo 'resume recovery was not confirmed'; exit 1; }
  unset MOCK_STUCK_RESUME_ONCE
}

run_unconfirmed_pause_case() {
  reset_case error
  export MOCK_IGNORE_PAUSE=1
  if run_runner; then :; else :; fi
  grep -q 'PAUSE_NOT_CONFIRMED_BUT_RESUMED' "$TMP/log" || { echo 'unconfirmed pause was reported as successful'; exit 1; }
  [ "$(cat "$TMP/torrent-state")" = Downloading ] || { echo 'torrent did not remain active'; exit 1; }
  unset MOCK_IGNORE_PAUSE
}

run_case ok 0
run_case delayed 0
run_case sent 1
run_case error 1
run_paused_case
run_failure_case pause
run_failure_case resume
run_stuck_resume_case
run_unconfirmed_pause_case

if "$RUNNER" bad >/dev/null 2>&1; then echo 'invalid hash unexpectedly accepted'; exit 1; fi
for setting in 'CHECK_INTERVAL=oops' 'MAX_RUNTIME=oops' 'CONSOLE_TIMEOUT=0' 'DELUGE_PORT=65536'; do
  if env CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" $setting "$RUNNER" "$HASH" >/dev/null 2>&1; then
    echo "invalid setting unexpectedly accepted: $setting"; exit 1
  fi
done
bash -n "$RUNNER" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/test-installer.sh"
python -m py_compile "$ROOT/scripts/configure-execute.py"
echo 'runner mock tests passed'
