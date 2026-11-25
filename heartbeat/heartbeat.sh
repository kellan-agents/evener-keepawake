#!/usr/bin/env bash
# evener-keepawake heartbeat — run as a Sprite service.
#
# Every INTERVAL seconds, decide whether evener is working and refresh the
# Sprite task `evener` (expire 5m) via the local Sprite Tasks API. The Sprite
# stays up while the task is live, so work continues after the browser tab is
# closed. When nothing is busy the task is allowed to expire (and is DELETEd
# on the busy->idle transition so the Sprite can sleep promptly).
#
# Busy means either:
#   1. a fresh session marker file in STATE_DIR (touched by the plugin hooks;
#      a marker untouched for MARKER_TTL seconds is stale and ignored), or
#   2. a live session daemon (from the evener run dir) that owns a running
#      shell job or a running delegate generation. "Running" rows from the
#      durable store are only trusted while the owning daemon's pid is alive,
#      so a crashed daemon can never hold the Sprite awake.
#
# Machine-specific values come from the optional shared config file
# (~/.config/evener-sprite/config, overridable via EVENER_SPRITE_CONFIG);
# per-tool EVENER_* env vars override the config file, and neutral built-in
# defaults sit under both. See config.example.
#
# Run once for testing:  heartbeat.sh --once
set -u

CONFIG_FILE="${EVENER_SPRITE_CONFIG:-$HOME/.config/evener-sprite/config}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# The service environment may not inherit the interactive PATH; the evener
# binary lives here.
PATH="$HOME/.local/bin:$PATH"

STATE_DIR="${EVENER_KEEPAWAKE_STATE:-$HOME/.local/state/evener-keepawake}"
RUN_DIR="${EVENER_KEEPAWAKE_RUN_DIR:-$HOME/.local/state/evener/run}"
SOCKET="${EVENER_KEEPAWAKE_SOCKET:-/.sprite/api.sock}"
TASK_NAME="${EVENER_KEEPAWAKE_TASK:-evener}"
INTERVAL="${EVENER_KEEPAWAKE_INTERVAL:-60}"
# 55 min: the task the last refresh created expires 5m later, so a killed
# session's worst case is awake ~60 min, never indefinitely.
MARKER_TTL="${EVENER_KEEPAWAKE_TTL:-3300}"
# Third busy source — legacy sessions. Sessions started before the keepawake
# plugin was installed never fire its hooks, so their in-turn model work is
# invisible to markers (their background jobs are already covered by the
# live-daemon check). While such a session works it writes its transcript, so
# recent activity on a legacy session means a live turn. The window is
# generous on purpose: this source can never affect post-install sessions, so
# its slower release tail (window + task expiry) applies only to the
# pre-install population, which shrinks to zero as sessions restart.
# Set the cutoff to the plugin's install moment; empty disables the source.
LEGACY_CUTOFF="${EVENER_KEEPAWAKE_LEGACY_CUTOFF:-${LEGACY_CUTOFF:-}}"
ACTIVE_WINDOW="${EVENER_KEEPAWAKE_ACTIVE_WINDOW:-240}"
LOG_FILE="$STATE_DIR/heartbeat.log"
MODE="${1:-}"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

put_task() {
  curl -s --max-time 10 --unix-socket "$SOCKET" \
    -H 'Content-Type: application/json' \
    -X PUT "http://sprite/v1/tasks/$TASK_NAME" -d '{"expire":"5m"}'
}

delete_task() {
  curl -s --max-time 10 --unix-socket "$SOCKET" \
    -X DELETE "http://sprite/v1/tasks/$TASK_NAME"
}

# Print the name of one fresh marker file, or nothing.
fresh_marker() {
  local now f m
  now=$(date +%s)
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      *.log) continue ;;
    esac
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    if (( now - m < MARKER_TTL )); then
      echo "${f##*/}"
      return 0
    fi
  done
  return 1
}

# Print "pid<TAB>session_id" for every live evener session daemon.
# The run-dir <pid>.json files map each daemon process to the root session it
# serves. Never log their contents: they carry a hub token.
live_daemons() {
  local j pid sid
  for j in "$RUN_DIR"/*.json; do
    [ -f "$j" ] || continue
    pid=$(sed -n 's/.*"pid":\([0-9]\{1,\}\).*/\1/p' "$j" | head -1)
    sid=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$j" | head -1)
    [ -n "$pid" ] && [ -n "$sid" ] || continue
    if [ -r "/proc/$pid/cmdline" ] \
       && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q evener; then
      printf '%s\t%s\n' "$pid" "$sid"
    fi
  done
}

# Echo a reason string if a live daemon owns running work, else return 1.
live_work_reason() {
  local pid sid out
  if ! command -v evener >/dev/null 2>&1; then
    if [ "${DOCTOR_MISSING_LOGGED:-0}" -eq 0 ]; then
      log "evener binary not found on PATH; running-job detection disabled"
      DOCTOR_MISSING_LOGGED=1
    fi
    return 1
  fi
  while IFS=$'\t' read -r pid sid; do
    [ -n "$pid" ] && [ -n "$sid" ] || continue
    if ! out=$(evener doctor jobs --json "$sid" 2>>"$LOG_FILE"); then
      log "doctor jobs failed for session $sid; skipping it this beat"
      continue
    fi
    if printf '%s' "$out" | jq -e '([.jobs[]? | select(.status == "running")] | length) > 0' >/dev/null 2>&1; then
      echo "running job of session $sid"
      return 0
    fi
    if printf '%s' "$out" | jq -e '([.delegates[]? | select(.phase == "running")] | length) > 0' >/dev/null 2>&1; then
      echo "running delegate of session $sid"
      return 0
    fi
  done < <(live_daemons)
  return 1
}

# Echo a reason string if a pre-install session showed transcript activity
# within the window (a live turn in a session whose plugin hooks are absent).
legacy_active_reason() {
  local sid out
  [ -n "$LEGACY_CUTOFF" ] || return 1
  command -v evener >/dev/null 2>&1 || return 1
  if ! out=$(evener doctor sessions --json --since 168h 2>>"$LOG_FILE"); then
    return 1
  fi
  sid=$(printf '%s' "$out" | jq -r \
    --argjson now "$(date +%s)" \
    --argjson win "$ACTIVE_WINDOW" \
    --arg cutoff "$LEGACY_CUTOFF" \
    '.sessions[]
     | select(((.started_at | sub("\\.[0-9]+";"")) | fromdateiso8601) <
              (($cutoff | sub("\\.[0-9]+";"")) | fromdateiso8601))
     | select(((.last_activity | sub("\\.[0-9]+";"")) | fromdateiso8601) >= ($now - $win))
     | .session_id' 2>/dev/null | head -1)
  [ -n "$sid" ] && [ "$sid" != "null" ] || return 1
  echo "active legacy session $sid"
}

# One resource line per beat so downstream reports (the morning note) can
# compute overnight peaks. free's Mem row: $3 used, $7 available (kB).
sample() {
  local mem_used mem_avail swap_used disk_pct
  read -r mem_used mem_avail <<<"$(free -k | awk '/^Mem:/{print $3, $7}')"
  swap_used=$(free -k | awk '/^Swap:/{print $3}')
  disk_pct=$(df -P / | awk 'NR==2{gsub(/%/,""); print $(NF-1)}')
  log "sample mem_used_kb=${mem_used:-?} mem_avail_kb=${mem_avail:-?} swap_used_kb=${swap_used:-?} disk_used_pct=${disk_pct:-?}"
}

beat() {
  local reason=""
  sample
  reason=$(fresh_marker || true)
  if [ -z "$reason" ]; then
    reason=$(live_work_reason || true)
  fi
  if [ -z "$reason" ]; then
    reason=$(legacy_active_reason || true)
  fi

  if [ -n "$reason" ]; then
    if ! put_task; then
      log "refresh FAILED (curl exit $?); busy reason: $reason"
    elif [ "$WAS_BUSY" -eq 0 ]; then
      log "awake: $reason"
    else
      log "refresh: $reason"
    fi
    WAS_BUSY=1
    IDLE_BEATS=0
  else
    if [ "$WAS_BUSY" -eq 1 ]; then
      if ! delete_task; then
        log "task delete FAILED (curl exit $?); task will expire on its own"
      else
        log "idle: released task $TASK_NAME"
      fi
    fi
    WAS_BUSY=0
    IDLE_BEATS=$((IDLE_BEATS + 1))
    # A liveness line every 15 idle beats (~15 min) so the log shows the
    # service is alive without spamming, plus an audit snapshot: whether the
    # task list agrees with us and what could hold the Sprite awake.
    if (( IDLE_BEATS % 15 == 1 )); then
      log "idle beat ${IDLE_BEATS} $(status_summary)"
    fi
  fi
}

# One-line audit snapshot: what the Tasks API holds vs what we think.
# "task=present while idle" means something else created a task (or our
# DELETE failed); "markers=/daemons=" name the session leads to chase.
status_summary() {
  local tasks markers daemons
  tasks=$(curl -s --max-time 5 --unix-socket "$SOCKET" \
    "http://sprite/v1/tasks" \
    | jq -r 'if (.tasks | length) > 0 then "present" else "absent" end' 2>/dev/null) \
    || tasks="unknown"
  markers=$(find "$STATE_DIR" -maxdepth 1 -type f ! -name '*.log' 2>/dev/null | wc -l)
  daemons=$(live_daemons | wc -l)
  printf '[task=%s markers=%s live_daemons=%s]' "${tasks:-unknown}" "$markers" "$daemons"
}

WAS_BUSY=0
IDLE_BEATS=0
log "heartbeat starting (state=$STATE_DIR run_dir=$RUN_DIR interval=${INTERVAL}s ttl=${MARKER_TTL}s task=$TASK_NAME)"
PREV=$(date +%s)
while true; do
  beat
  if [ "$MODE" = "--once" ]; then
    break
  fi
  sleep "$INTERVAL"
  # Loop-start-to-loop-start normally lands a beat-duration past INTERVAL.
  # A larger jump means the loop was frozen somewhere in the cycle — the
  # Sprite paused (this service freezes with the machine) or the host
  # stalled. That gap is the sleep/wake record the log would otherwise miss,
  # so measure the whole cycle, not just the sleep, and never depend on
  # nanosleep semantics: a freeze mid-sleep can let the timer expire while
  # frozen and return immediately on resume.
  NOW=$(date +%s)
  GAP=$(( NOW - PREV - INTERVAL ))
  if (( GAP > 30 )); then
    log "resumed after ${GAP}s gap (sprite pause or stall) $(status_summary)"
  fi
  PREV=$NOW
done
