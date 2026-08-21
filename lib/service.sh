#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - service management
# Runs the server with nohup + pidfile (no systemd inside proot), waits for
# /health, exposes start/stop/restart/status/logs and an optional watchdog.
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

SERVER_LOG="$LOG_DIR/openwebui.log"

svc_pid() { [[ -f "$PID_FILE" ]] && cat "$PID_FILE" 2>/dev/null || echo ""; }

svc_is_running() {
  local pid
  pid="$(svc_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

health_ok() {
  # health_ok [port] -> 0 when /health answers
  local port="${1:-$OWI_PORT}"
  curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null
}

wait_healthy() {
  local port="$1" tries="$2" i
  for ((i = 1; i <= tries; i++)); do
    if health_ok "$port"; then return 0; fi
    sleep 2
  done
  return 1
}

svc_start() {
  local port="${OWI_PORT:-8080}"
  if is_dry_run; then
    dry_msg "nohup $VENV_DIR/bin/open-webui serve --host 0.0.0.0 --port $port"
    return 0
  fi
  if svc_is_running && health_ok "$port"; then
    ow_ok "service already running (pid $(svc_pid))"
    return 0
  fi
  if svc_is_running; then
    ow_info "stale pid detected; restarting"
    svc_stop
  fi

  [[ -x "$VENV_DIR/bin/open-webui" ]] || { ow_err "open-webui executable not found - run install.sh first"; return 1; }
  [[ -f "$ENV_FILE" ]] || { ow_err "environment file missing - run install.sh first"; return 1; }

  ensure_dir "$LOG_DIR"
  rm -f "$WATCHDOG_STOP_FILE"

  ow_info "starting Open WebUI on 0.0.0.0:${port} (log: $SERVER_LOG)"

  # Source the env file, then launch detached.
  (
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    cd "$OWI_INSTALL_DIR" || exit 1
    exec nohup "$VENV_DIR/bin/open-webui" serve --host 0.0.0.0 --port "$port" \
      >>"$SERVER_LOG" 2>&1 &
    echo $! > "$PID_FILE"
  )
  # The subshell above must have written the pidfile; verify
  if [[ ! -s "$PID_FILE" ]]; then ow_err "failed to record service pid"; return 1; fi

  ow_info "waiting for /health (first start runs database migrations; can take minutes)..."
  if wait_healthy "$port" 120; then
    ow_ok "Open WebUI is up: http://127.0.0.1:${port}  (pid $(svc_pid))"
    return 0
  fi
  ow_err "service did not become healthy within the timeout. Last log lines:"
  tail -n 30 "$SERVER_LOG" 2>/dev/null | sed 's/^/  /'
  return 1
}

svc_stop() {
  local pid
  pid="$(svc_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    ow_info "stopping Open WebUI (pid $pid)"
    if ! is_dry_run; then
      kill "$pid" 2>/dev/null
      for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -9 "$pid" 2>/dev/null || true
    else
      dry_msg "kill $pid"
    fi
  else
    ow_info "service is not running"
  fi
  rm -f "$PID_FILE"
  # Keep any child uvicorn workers from lingering
  if ! is_dry_run; then
    pkill -f "open_webui.main:app" 2>/dev/null || true
  fi
  return 0
}

svc_restart() { svc_stop; svc_start; }

svc_status() {
  if svc_is_running; then
    local port="${OWI_PORT:-8080}"
    if health_ok "$port"; then
      printf 'running (pid %s) - healthy at http://127.0.0.1:%s\n' "$(svc_pid)" "$port"
    else
      printf 'running (pid %s) - NOT healthy yet (still starting or crashed)\n' "$(svc_pid)"
    fi
  else
    printf 'not running\n'
  fi
}

svc_logs() { tail -n "${1:-100}" -f "$SERVER_LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Watchdog: restart the service if it dies (with backoff). Ctrl-C to stop,
# or touch the stop file.
# ---------------------------------------------------------------------------
svc_watch() {
  local interval="${1:-30}" backoff=5 max_backoff=60 fails=0
  ow_info "watchdog active: checks every ${interval}s (ctrl-c or touch $WATCHDOG_STOP_FILE to stop)"
  while :; do
    if [[ -f "$WATCHDOG_STOP_FILE" ]]; then ow_info "watchdog stop requested"; break; fi
    if svc_is_running && health_ok; then
      fails=0; backoff=5
    else
      fails=$((fails + 1))
      ow_warn "service unhealthy (${fails}x); restarting in ${backoff}s"
      sleep "$backoff"
      svc_start || true
      backoff=$((backoff * 2)); ((backoff > max_backoff)) && backoff=$max_backoff
    fi
    sleep "$interval"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # standalone openwebui-ctl entry
  cmd="${1:-status}"
  case "$cmd" in
    start)   svc_start ;;
    stop)    svc_stop ;;
    restart) svc_restart ;;
    status)  svc_status ;;
    logs)    svc_logs "${2:-100}" ;;
    watch)   svc_watch "${2:-30}" ;;
    *)       echo "usage: openwebui-ctl {start|stop|restart|status|logs [n]|watch [sec]}" >&2; exit 2 ;;
  esac
fi
