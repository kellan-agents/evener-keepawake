#!/usr/bin/env bash
# evener-keepawake test suite.
#
# Stub-based: every case runs in a fresh temp state dir with a stubbed
# `curl` (records task PUT/DELETE) and a stubbed `evener` (emits fixtures for
# `doctor jobs` / `doctor sessions`, logs every invocation). No real task
# API and no real evener is touched.
#
#   bash test/run.sh
#
# The whole suite nices itself (shared-machine courtesy).
set -u

if [ -z "${EVENER_KEEPAWAKE_TEST_NICED:-}" ]; then
  exec nice -n 19 env EVENER_KEEPAWAKE_TEST_NICED=1 bash "$0" "$@"
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
FAILED=""
TLIST=""

cleanup() {
  local d
  for d in $TLIST; do rm -rf "$d"; done
  if [ -n "${FAKE_DAEMON_PID:-}" ]; then
    kill "$FAKE_DAEMON_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Fresh temp world: state dir, run dir, stub bin dir, stub log. Sets T, STUB.
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/evener-keepawake-test.XXXXXX")
  TLIST="$TLIST $T"
  STUB="$T/stub.log"
  mkdir -p "$T/state" "$T/run" "$T/bin" "$T/home"

  # stub evener: logs every invocation; emits a fixture for doctor calls.
  cat >"$T/bin/evener" <<'EOF'
#!/usr/bin/env bash
printf 'evener args=%s\n' "$*" >>"${EVENER_KEEPAWAKE_TEST_LOG:?}"
case "${1:-} ${2:-}" in
  "doctor jobs")
    cat "${EVENER_KEEPAWAKE_TEST_JOBS:?}"
    ;;
  "doctor sessions")
    cat "${EVENER_KEEPAWAKE_TEST_SESSIONS:?}"
    ;;
esac
exit 0
EOF
  # stub curl: records "<METHOD> <task>" for task calls.
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method= url=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s %s\n' "${method:-GET}" "${url##*/}" >>"${EVENER_KEEPAWAKE_TEST_LOG:?}"
exit 0
EOF
  chmod +x "$T/bin/evener" "$T/bin/curl"

  export EVENER_KEEPAWAKE_STATE="$T/state"
  export EVENER_KEEPAWAKE_RUN_DIR="$T/run"
  export EVENER_SPRITE_CONFIG="$T/absent-config"
  export EVENER_KEEPAWAKE_TEST_LOG="$STUB"
  export EVENER_KEEPAWAKE_TEST_JOBS="$ROOT/test/fixtures/doctor-jobs-empty.json"
  export EVENER_KEEPAWAKE_TEST_SESSIONS='{"sessions":[],"unreadable":[]}'
  export PATH="$T/bin:$PATH"
  # Throwaway HOME keeps the tools' `PATH="$HOME/.local/bin:$PATH"` prepend
  # from shadowing the stubs with real binaries.
  export HOME="$T/home"
  unset LEGACY_CUTOFF EVENER_KEEPAWAKE_LEGACY_CUTOFF \
        EVENER_KEEPAWAKE_INTERVAL 2>/dev/null || true
}

puts() {
  if [ -f "$STUB" ]; then
    grep -c '^curl PUT' "$STUB" || true
  else
    echo 0
  fi
}

run_case() {
  local name=$1 out
  out=$(mktemp "${TMPDIR:-/tmp}/evener-keepawake-case.XXXXXX")
  setup
  if "$name" >"$out" 2>&1; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $name"
    echo "FAIL: $name"
    sed 's/^/    /' "$out"
  fi
  rm -f "$out"
}

# --- cases ------------------------------------------------------------------

fresh_marker_holds_task() {
  : >"$T/state/test-sid-0001"
  bash "$ROOT/heartbeat/heartbeat.sh" --once || { echo "run failed"; return 1; }
  [ "$(puts)" -ge 1 ] || { echo "no task PUT for fresh marker:"; cat "$STUB" 2>/dev/null; return 1; }
  grep -q "awake: " "$T/state/heartbeat.log" \
    || { echo "no awake: line:"; cat "$T/state/heartbeat.log"; return 1; }
}

stale_marker_ignored() {
  touch -d '2 hours ago' "$T/state/test-sid-0001"
  bash "$ROOT/heartbeat/heartbeat.sh" --once || { echo "run failed"; return 1; }
  [ "$(puts)" = "0" ] || { echo "stale marker held the task"; return 1; }
  grep -q "idle beat" "$T/state/heartbeat.log" \
    || { echo "no idle path in log:"; cat "$T/state/heartbeat.log"; return 1; }
}

busy_to_idle_releases_task() {
  # busy->idle needs two beats of one process (WAS_BUSY is in-process state),
  # so drive the loop (not --once) with a 1s interval and a short run.
  : >"$T/state/test-sid-0001"
  EVENER_KEEPAWAKE_INTERVAL=1 bash "$ROOT/heartbeat/heartbeat.sh" &
  local hb=$!
  sleep 1.3
  rm -f "$T/state/test-sid-0001"
  sleep 1.5
  kill "$hb" 2>/dev/null
  wait "$hb" 2>/dev/null
  [ "$(puts)" -ge 1 ] || { echo "no PUT on the busy beat"; return 1; }
  grep -q '^curl DELETE' "$STUB" || { echo "no DELETE on busy->idle:"; cat "$STUB"; return 1; }
  grep -q "idle: released task evener" "$T/state/heartbeat.log" \
    || { echo "no release line:"; cat "$T/state/heartbeat.log"; return 1; }
}

running_job_of_live_daemon_holds() {
  # A decoy process with "evener" in argv[0] stands in for the live daemon
  # (live_daemons checks /proc/<pid>/cmdline for an evener process).
  bash -c 'exec -a evener-fixture-daemon sleep 60' &
  FAKE_DAEMON_PID=$!
  printf '{"pid":%s,"session_id":"test-sid-0001"}\n' "$FAKE_DAEMON_PID" >"$T/run/info.json"
  export EVENER_KEEPAWAKE_TEST_JOBS="$ROOT/test/fixtures/doctor-jobs-running.json"
  bash "$ROOT/heartbeat/heartbeat.sh" --once || { echo "run failed"; return 1; }
  [ "$(puts)" -ge 1 ] || { echo "no task PUT for running job:"; cat "$STUB"; return 1; }
  grep -q "running job of session test-sid-0001" "$T/state/heartbeat.log" \
    || { echo "no running-job reason line:"; cat "$T/state/heartbeat.log"; return 1; }
  kill "$FAKE_DAEMON_PID" 2>/dev/null || true
  unset FAKE_DAEMON_PID
}

legacy_source_disabled_by_default() {
  : >"$T/state/test-sid-0001"   # nothing else busy either; pure idle beat
  rm -f "$T/state/test-sid-0001"
  bash "$ROOT/heartbeat/heartbeat.sh" --once || { echo "run failed"; return 1; }
  if [ -f "$STUB" ] && grep -q "doctor sessions" "$STUB"; then
    echo "legacy source consulted doctor sessions with LEGACY_CUTOFF unset"
    return 1
  fi
  grep -q "idle beat" "$T/state/heartbeat.log" \
    || { echo "no idle path in log:"; cat "$T/state/heartbeat.log"; return 1; }
}

metadata_neutral() {
  # Needles are concatenated so this file itself carries no machine-identity
  # strings (they are checked for, never spelled out).
  local machine
  machine="gray""goo"
  if grep -rn -e "$machine" "$ROOT/.claude-plugin/" "$ROOT/plugins/" "$ROOT/README.md"; then
    echo "machine name found in plugin metadata or README"
    return 1
  fi
}

# --- run --------------------------------------------------------------------

cd "$ROOT"
for c in fresh_marker_holds_task stale_marker_ignored \
         busy_to_idle_releases_task running_job_of_live_daemon_holds \
         legacy_source_disabled_by_default metadata_neutral; do
  run_case "$c"
done

echo "evener-keepawake tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "failed:$FAILED"; exit 1; }
