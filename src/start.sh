#!/usr/bin/env bash
set -euo pipefail

# ---------- Config (overridable by env) ----------
PYTHON="${PYTHON:-/opt/venv/bin/python}"

# Find ComfyUI directory
COMFYUI_DIR="${COMFYUI_DIR:-/home/comfyuser/workspace/ComfyUI}"

COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
# Space-separated flags are allowed; will be split safely below
COMFYUI_FLAGS="${COMFYUI_FLAGS:---disable-auto-launch --disable-metadata-preview}"

FILEBROWSER_BIN="${FILEBROWSER_BIN:-/home/comfyuser/filebrowser}"
FILEBROWSER_ROOT="${FILEBROWSER_ROOT:-/home/comfyuser/workspace}"
FILEBROWSER_HOST="${FILEBROWSER_HOST:-0.0.0.0}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8080}"

COMFYUI_URL="http://127.0.0.1:${COMFYUI_PORT}"
FILEBROWSER_URL="http://127.0.0.1:${FILEBROWSER_PORT}"

HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"   # seconds between liveness checks
HEALTH_RETRIES_START="${HEALTH_RETRIES_START:-60}"     # seconds to wait for initial readiness (increased)

PID_COMFYUI=""
PID_FILEBROWSER=""
SHUTDOWN_REQUESTED=false

# ---------- Helpers ----------
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { log "Missing command: $1"; exit 127; }; }
health_check() { curl -fsS -m 5 "$1" >/dev/null 2>&1; }

wait_healthy() {
  local url=$1 name=$2 retries=${3:-$HEALTH_RETRIES_START}
  local attempt=0
  log "Waiting for $name to become healthy at $url (max ${retries}s)..."
  
  while [ $attempt -lt $retries ]; do
    if health_check "$url"; then 
      log "$name is healthy!"
      return 0
    fi
    
    # Show progress every 10 seconds
    if [ $((attempt % 10)) -eq 0 ] && [ $attempt -gt 0 ]; then
      log "Still waiting for $name... (${attempt}/${retries}s)"
    fi
    
    sleep 1
    attempt=$((attempt + 1))
  done
  
  log "$name did not become healthy at $url in ${retries}s"
  return 1
}

# ---------- Service Launchers ----------
start_service() {
  local name=$1; shift
  local url=$1; shift
  log "Starting $name with command: $*"
  
  # Start the service in background
  "$@" &
  local pid=$!
  log "$name started with pid=$pid"
  
  # Wait for it to become healthy
  if wait_healthy "$url" "$name"; then
    log "$name ready at $url"
    echo "$pid"
    return 0
  else
    log "Failed to start $name - killing process"
    kill -9 "$pid" 2>/dev/null || true
    return 1
  fi
}

# ---------- Signals ----------
handle_signal() {
  local sig="${1:-TERM}"
  log "Received $sig; stopping services..."
  SHUTDOWN_REQUESTED=true
  [[ -n "$PID_COMFYUI" ]]    && kill -TERM "$PID_COMFYUI" 2>/dev/null || true
  [[ -n "$PID_FILEBROWSER" ]]&& kill -TERM "$PID_FILEBROWSER" 2>/dev/null || true
}
trap 'handle_signal TERM' TERM
trap 'handle_signal INT'  INT

# ---------- Pre-flight ----------
require_cmd curl
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  log "Python not found at $PYTHON"; exit 127
fi
if [[ -z "$COMFYUI_DIR" || ! -f "$COMFYUI_DIR/main.py" ]]; then
    log "ComfyUI not found or main.py is missing."
    # Add any additional diagnostic info if needed
    exit 1
fi

# Test ComfyUI import before starting
log "Testing ComfyUI import..."
cd "$COMFYUI_DIR"
if ! "$PYTHON" -c "
import sys
sys.path.insert(0, '.')
try:
    import execution, server
    print('ComfyUI imports successful')
except ImportError as e:
    print(f'ComfyUI import failed: {e}')
    sys.exit(1)
"; then
  log "ComfyUI import test failed - cannot start service"
  exit 1
fi

# ---------- Start Services ----------
log "Launching services..."

# Organize files before launching services
bash "$(dirname "$0")/file_organizer.sh"

# Split COMFYUI_FLAGS on spaces into an array safely (SC2206 ok here)
# shellcheck disable=SC2206
EXTRA_FLAGS=( $COMFYUI_FLAGS )
COMFY_CMD=( "$PYTHON" "$COMFYUI_DIR/main.py" --listen "$COMFYUI_HOST" --port "$COMFYUI_PORT" )
COMFY_CMD+=( "${EXTRA_FLAGS[@]}" )

log "Starting ComfyUI..."
PID_COMFYUI=$(start_service "ComfyUI" "$COMFYUI_URL" "${COMFY_CMD[@]}") || {
  log "Failed to start ComfyUI"
  exit 1
}

# ---------- Start FileBrowser (optional) ----------
if [[ -x "$FILEBROWSER_BIN" ]]; then
  FB_CMD=( "$FILEBROWSER_BIN" -r "$FILEBROWSER_ROOT" -a "$FILEBROWSER_HOST" -p "$FILEBROWSER_PORT" )
  if [[ -n "${FB_USERNAME:-}" && -n "${FB_PASSWORD:-}" ]]; then
    FB_CMD+=( --username "$FB_USERNAME" --password "$FB_PASSWORD" )
  fi
  PID_FILEBROWSER=$(start_service "FileBrowser" "$FILEBROWSER_URL" "${FB_CMD[@]}") || {
    log "FileBrowser startup failed, but continuing..."
  }
else
  log "FileBrowser binary not found at $FILEBROWSER_BIN, skipping..."
fi

# ---------- Health Monitoring Loop ----------
log "Service management started. Monitoring health every ${HEALTH_CHECK_INTERVAL}s..."
while ! $SHUTDOWN_REQUESTED; do
    # --- Monitor ComfyUI (Critical Service) ---
    if ! kill -0 "$PID_COMFYUI" 2>/dev/null; then
        log "ComfyUI process (PID: $PID_COMFYUI) has unexpectedly died. Shutting down container."
        handle_signal "TERM" # Trigger a clean shutdown of other services
        exit 1
    elif ! health_check "$COMFYUI_URL"; then
        log "Warning: ComfyUI is running but failing health checks. It may be overloaded or stuck."
    fi

    # --- Monitor FileBrowser (Non-Critical Service) ---
    if [[ -n "$PID_FILEBROWSER" ]] && kill -0 "$PID_FILEBROWSER" 2>/dev/null; then
        if ! health_check "$FILEBROWSER_URL"; then
            log "Warning: FileBrowser is running but failing health checks."
        fi
    elif [[ -n "$PID_FILEBROWSER" ]]; then
        log "FileBrowser process has died, but continuing without it..."
        PID_FILEBROWSER=""
    fi

    sleep "$HEALTH_CHECK_INTERVAL"
done

log "Service manager shutting down normally"