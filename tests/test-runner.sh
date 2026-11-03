#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/reannounce-new.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fake-deluge-console"
CLOCK="$TMP/fake-clock"
cat > "$CLOCK" <<'CLOCK'
#!/usr/bin/env bash
n=0; [ ! -f "$CLOCK_STATE" ] || n=$(cat "$CLOCK_STATE")
n=$((n + 1)); printf '%s' "$n" > "$CLOCK_STATE"; printf '%s\n' "$n"
CLOCK
cat > "$FAKE" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_CALLS"
case "$*" in
  *"info -v"*)
    n=0; [ ! -f "$MOCK_STATE" ] || n=$(cat "$MOCK_STATE")
    n=$((n + 1)); printf '%s' "$n" > "$MOCK_STATE"
    echo "State: ${MOCK_TORRENT_STATE:-Downloading}"
    if [ -f "$MOCK_ANNOUNCES" ]; then
      echo 'Tracker status: mock: Announce OK'
    else
      case "$MOCK_MODE:$n" in
        ok:*) echo 'Tracker status: mock: Announce OK';;
        delayed:1) echo 'Tracker status: mock: Announce Sent';;
        delayed:*) echo 'Tracker status: mock: Announce OK';;
        sent:*) echo 'Tracker status: mock: Announce Sent';;
        *) echo 'Tracker status: mock: Tracker Error';;
      esac
    fi
    ;;
  *"pause "*)
    n=0; [ ! -f "$MOCK_PAUSE_ATTEMPTS" ] || n=$(cat "$MOCK_PAUSE_ATTEMPTS")
    n=$((n + 1)); printf '%s' "$n" > "$MOCK_PAUSE_ATTEMPTS"
    if [ "${MOCK_FAIL_PAUSE_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ]; then
      echo 'mock pause failure' >&2
      exit 1
    fi
    echo pause >> "$MOCK_ACTIONS"
    ;;
  *"resume "*)
    n=0; [ ! -f "$MOCK_RESUME_ATTEMPTS" ] || n=$(cat "$MOCK_RESUME_ATTEMPTS")
    n=$((n + 1)); printf '%s' "$n" > "$MOCK_RESUME_ATTEMPTS"
    if [ "${MOCK_FAIL_RESUME_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ]; then
      echo 'mock resume failure' >&2
      exit 1
    fi
    echo resume >> "$MOCK_ACTIONS"
    if grep -q '^pause
    ;;
esac
MOCK
chmod +x "$FAKE" "$CLOCK"
HASH=0123456789abcdef0123456789abcdef01234567
run_case() {
  mode=$1; expected=$2
  rm -f "$TMP/state" "$TMP/actions" "$TMP/announces" "$TMP/log" "$TMP/clock-state" "$TMP/pause-attempts" "$TMP/resume-attempts"
  export MOCK_STATE="$TMP/state" MOCK_MODE="$mode" MOCK_ACTIONS="$TMP/actions" MOCK_ANNOUNCES="$TMP/announces"
  export MOCK_PAUSE_ATTEMPTS="$TMP/pause-attempts" MOCK_RESUME_ATTEMPTS="$TMP/resume-attempts"
  export CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls"
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  count=0; [ ! -f "$TMP/actions" ] || count=$(wc -l < "$TMP/actions")
  [ "$count" -eq "$((expected * 2))" ] || { echo "$mode: expected $((expected * 2)) pause/resume actions, got $count"; exit 1; }
  if [ "$expected" -gt 0 ]; then
    if [ "$(sed -n '1p' "$TMP/actions")" != pause ] || [ "$(sed -n '2p' "$TMP/actions")" != resume ]; then
      echo "$mode: pause/resume order incorrect"
      exit 1
    fi
  fi
  ! grep -q "reannounce " "$TMP/calls" || { echo "$mode: direct reannounce must not be called"; exit 1; }
  grep -F -- "-c $TMP/jerry-config connect 127.0.0.1:58846;" "$TMP/calls" >/dev/null
}
run_failure_retry_case() {
  failure=$1
  rm -f "$TMP/state" "$TMP/actions" "$TMP/announces" "$TMP/log" "$TMP/clock-state" "$TMP/pause-attempts" "$TMP/resume-attempts"
  export MOCK_STATE="$TMP/state" MOCK_MODE=error MOCK_ACTIONS="$TMP/actions" MOCK_ANNOUNCES="$TMP/announces"
  export MOCK_PAUSE_ATTEMPTS="$TMP/pause-attempts" MOCK_RESUME_ATTEMPTS="$TMP/resume-attempts"
  export CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls"
  unset MOCK_FAIL_PAUSE_ONCE MOCK_FAIL_RESUME_ONCE
  if [ "$failure" = pause ]; then MOCK_FAIL_PAUSE_ONCE=1; export MOCK_FAIL_PAUSE_ONCE; else MOCK_FAIL_RESUME_ONCE=1; export MOCK_FAIL_RESUME_ONCE; fi
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  [ "$(cat "$TMP/resume-attempts")" -ge 1 ] || { echo "$failure: resume was not attempted"; exit 1; }
  if [ "$failure" = pause ]; then
    [ "$(cat "$TMP/pause-attempts")" -ge 2 ] || { echo 'pause failure was not retried'; exit 1; }
  else
    [ "$(cat "$TMP/pause-attempts")" -eq 1 ] || { echo 'resume failure must not repeat pause'; exit 1; }
    [ "$(cat "$TMP/resume-attempts")" -ge 2 ] || { echo 'resume failure was not retried'; exit 1; }
  fi
  grep -q 'SUCCESS | Announce OK' "$TMP/log"
  unset MOCK_FAIL_PAUSE_ONCE MOCK_FAIL_RESUME_ONCE
}
run_paused_case() {
  rm -f "$TMP/state" "$TMP/actions" "$TMP/announces" "$TMP/log" "$TMP/clock-state" "$TMP/pause-attempts" "$TMP/resume-attempts"
  export MOCK_STATE="$TMP/state" MOCK_MODE=error MOCK_ACTIONS="$TMP/actions" MOCK_ANNOUNCES="$TMP/announces"
  export MOCK_PAUSE_ATTEMPTS="$TMP/pause-attempts" MOCK_RESUME_ATTEMPTS="$TMP/resume-attempts"
  export CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls" MOCK_TORRENT_STATE=Paused
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  [ ! -s "$TMP/actions" ] || { echo 'paused torrent was modified'; exit 1; }
  grep -q 'SKIPPED | Torrent was already paused' "$TMP/log"
  unset MOCK_TORRENT_STATE
}
run_case ok 0
run_case delayed 0
run_case sent 1
run_case error 1
run_paused_case
run_failure_retry_case pause
run_failure_retry_case resume
if "$RUNNER" bad >/dev/null 2>&1; then echo 'invalid hash unexpectedly accepted'; exit 1; fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 CHECK_INTERVAL=oops "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'invalid check interval unexpectedly accepted'; exit 1
fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 MAX_RUNTIME=oops "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'invalid max runtime unexpectedly accepted'; exit 1
fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 CONSOLE_TIMEOUT=0 "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'zero console timeout unexpectedly accepted'; exit 1
fi
bash -n "$RUNNER" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/test-installer.sh"
python -m py_compile "$ROOT/scripts/configure-execute.py"
echo 'runner mock tests passed'
 "$MOCK_ACTIONS"; then : > "$MOCK_ANNOUNCES"; fi
    ;;
esac
MOCK
chmod +x "$FAKE" "$CLOCK"
HASH=0123456789abcdef0123456789abcdef01234567
run_case() {
  mode=$1; expected=$2
  rm -f "$TMP/state" "$TMP/actions" "$TMP/announces" "$TMP/log" "$TMP/clock-state" "$TMP/pause-attempts" "$TMP/resume-attempts"
  export MOCK_STATE="$TMP/state" MOCK_MODE="$mode" MOCK_ACTIONS="$TMP/actions" MOCK_ANNOUNCES="$TMP/announces"
  export MOCK_PAUSE_ATTEMPTS="$TMP/pause-attempts" MOCK_RESUME_ATTEMPTS="$TMP/resume-attempts"
  export CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls"
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  count=0; [ ! -f "$TMP/actions" ] || count=$(wc -l < "$TMP/actions")
  [ "$count" -eq "$((expected * 2))" ] || { echo "$mode: expected $((expected * 2)) pause/resume actions, got $count"; exit 1; }
  if [ "$expected" -gt 0 ]; then
    if [ "$(sed -n '1p' "$TMP/actions")" != pause ] || [ "$(sed -n '2p' "$TMP/actions")" != resume ]; then
      echo "$mode: pause/resume order incorrect"
      exit 1
    fi
  fi
  ! grep -q "reannounce " "$TMP/calls" || { echo "$mode: direct reannounce must not be called"; exit 1; }
  grep -F -- "-c $TMP/jerry-config connect 127.0.0.1:58846;" "$TMP/calls" >/dev/null
}
run_failure_retry_case() {
  failure=$1
  rm -f "$TMP/state" "$TMP/actions" "$TMP/announces" "$TMP/log" "$TMP/clock-state" "$TMP/pause-attempts" "$TMP/resume-attempts"
  export MOCK_STATE="$TMP/state" MOCK_MODE=error MOCK_ACTIONS="$TMP/actions" MOCK_ANNOUNCES="$TMP/announces"
  export MOCK_PAUSE_ATTEMPTS="$TMP/pause-attempts" MOCK_RESUME_ATTEMPTS="$TMP/resume-attempts"
  export CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls"
  unset MOCK_FAIL_PAUSE_ONCE MOCK_FAIL_RESUME_ONCE
  if [ "$failure" = pause ]; then MOCK_FAIL_PAUSE_ONCE=1; export MOCK_FAIL_PAUSE_ONCE; else MOCK_FAIL_RESUME_ONCE=1; export MOCK_FAIL_RESUME_ONCE; fi
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  [ "$(cat "$TMP/resume-attempts")" -ge 1 ] || { echo "$failure: resume was not attempted"; exit 1; }
  if [ "$failure" = pause ]; then
    [ "$(cat "$TMP/pause-attempts")" -ge 2 ] || { echo 'pause failure was not retried'; exit 1; }
  else
    [ "$(cat "$TMP/pause-attempts")" -eq 1 ] || { echo 'resume failure must not repeat pause'; exit 1; }
    [ "$(cat "$TMP/resume-attempts")" -ge 2 ] || { echo 'resume failure was not retried'; exit 1; }
  fi
  grep -q 'SUCCESS | Announce OK' "$TMP/log"
  unset MOCK_FAIL_PAUSE_ONCE MOCK_FAIL_RESUME_ONCE
}
run_case ok 0
run_case delayed 0
run_case sent 1
run_case error 1
run_failure_retry_case pause
run_failure_retry_case resume
if "$RUNNER" bad >/dev/null 2>&1; then echo 'invalid hash unexpectedly accepted'; exit 1; fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 CHECK_INTERVAL=oops "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'invalid check interval unexpectedly accepted'; exit 1
fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 MAX_RUNTIME=oops "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'invalid max runtime unexpectedly accepted'; exit 1
fi
bash -n "$RUNNER" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/test-installer.sh"
python -m py_compile "$ROOT/scripts/configure-execute.py"
echo 'runner mock tests passed'
