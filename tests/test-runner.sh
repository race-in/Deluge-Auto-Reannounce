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
    if [ -f "$MOCK_REANNOUNCES" ]; then
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
  *"reannounce "*) echo reannounce >> "$MOCK_REANNOUNCES";;
esac
MOCK
chmod +x "$FAKE" "$CLOCK"
HASH=0123456789abcdef0123456789abcdef01234567
run_case() {
  mode=$1; expected=$2; rm -f "$TMP/state" "$TMP/reannounces" "$TMP/log" "$TMP/clock-state"
  export MOCK_STATE="$TMP/state" MOCK_MODE="$mode" MOCK_REANNOUNCES="$TMP/reannounces" CLOCK_STATE="$TMP/clock-state" MOCK_CALLS="$TMP/calls"
  CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_CONFIG_DIR="$TMP/jerry-config" DELUGE_PORT=58846 \
    NOW_COMMAND="$CLOCK" INITIAL_DELAY=0 CHECK_INTERVAL=0.001 MAX_RUNTIME=300 \
    REANNOUNCE_INTERVAL=30 SENT_TIMEOUT=3 LOG_FILE="$TMP/log" \
    "$RUNNER" "$HASH" Test >/dev/null 2>&1
  count=0; [ ! -f "$TMP/reannounces" ] || count=$(wc -l < "$TMP/reannounces")
  [ "$count" -eq "$expected" ] || { echo "$mode: expected $expected reannounces, got $count"; exit 1; }
  grep -F -- "-c $TMP/jerry-config connect 127.0.0.1:58846;" "$TMP/calls" >/dev/null
}
run_case ok 0
run_case delayed 0
run_case sent 1
run_case error 1
if "$RUNNER" bad >/dev/null 2>&1; then echo 'invalid hash unexpectedly accepted'; exit 1; fi
if CONFIG_FILE="$TMP/no-config" DELUGE_CONSOLE="$FAKE" DELUGE_PORT=58846 MAX_RUNTIME=oops "$RUNNER" "$HASH" >/dev/null 2>&1; then
  echo 'invalid runtime unexpectedly accepted'; exit 1
fi
bash -n "$RUNNER" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/test-installer.sh"
python -m py_compile "$ROOT/scripts/configure-execute.py"
echo 'runner mock tests passed'
