#!/bin/bash
# ==================================================================================
# CATALYST STARTUP (RunPod / ComfyUI) — quiet edition
# - Network readiness checks
# - Safe Python probe (no GPU touch)
# - Auto CPU fallback when no CUDA
# - Timed downloads
# ==================================================================================

set -Eeuo pipefail

# --- Environment Variables and Paths ---
LOG_PREFIX="[STARTUP]"
COMFYUI_DIR="/home/comfyuser/workspace/ComfyUI"
PYTHON_EXEC="/opt/venv/bin/python"
SCRIPTS_DIR="/home/comfyuser/scripts"
STARTUP_ERROR_LOG="/home/comfyuser/workspace/startup_errors.log"
MODELS_DIR="/home/comfyuser/workspace/models"
DOWNLOADS_TMP="/home/comfyuser/workspace/downloads_tmp"

# Prefer the container venv everywhere
export PATH="/opt/venv/bin:${PATH}"
export PYTHONNOUSERSITE=1
# Hugging Face cache to writable location
export HF_HOME="/home/comfyuser/workspace/downloads_tmp/huggingface/.hf"
# Default secret location if not provided at runtime
: "${SECURITY_TOKEN_VAULT_PATH:=/run/secrets/token}"

# --- Logging (quiet by default; set LOG_LEVEL=debug for more) ---
: "${LOG_LEVEL:=info}"
log()       { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
log_debug() { [ "${LOG_LEVEL}" = "debug" ] && log "[debug] $*"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} [ERROR] $*" | tee -a "${STARTUP_ERROR_LOG}"; }

# --- Signal Handling for Graceful Shutdown ---
term_handler() {
  log "SIGTERM received. Shutting down…"
  jobs -p | xargs -r kill || true
  wait || true
  log "Services stopped."
  exit 0
}
trap 'kill ${!} 2>/dev/null || true; term_handler' SIGTERM

# --- Wait Helpers ---
wait_for_path() {
  local path="$1"; local timeout="${2:-30}"; local counter=0
  while [ ! -e "$path" ] && [ $counter -lt $timeout ]; do sleep 1; counter=$((counter + 1)); done
  [ -e "$path" ] || { log_error "Timeout waiting for path: $path"; return 1; }
  return 0
}

# --- Network Readiness Check ---
wait_for_network_ready() {
  local timeout="${1:-90}" max_attempts=$((timeout / 3)) attempt=0
  log "Checking network… (timeout ${timeout}s)"
  while [ $attempt -lt $max_attempts ]; do
    local all_ready=true
    curl -s --connect-timeout 5 --max-time 10 "https://8.8.8.8" >/dev/null 2>&1 || all_ready=false
    $all_ready && curl -s --connect-timeout 5 --max-time 10 "https://google.com" >/dev/null 2>&1 || all_ready=false
    $all_ready && curl -s --connect-timeout 5 --max-time 10 "https://civitai.com" >/dev/null 2>&1 || all_ready=false
    $all_ready && curl -s --connect-timeout 5 --max-time 10 "https://huggingface.co" >/dev/null 2>&1 || all_ready=false
    if $all_ready; then log "Network OK"; return 0; fi
    attempt=$((attempt + 1)); sleep 3
  done
  log_error "Network check failed"
  return 1
}

# --- Safe Python/ComfyUI probe (no GPU-touching imports) ---
python_env_probe() {
  log_debug "Probing Python/ComfyUI…"
  "${PYTHON_EXEC}" - <<'PY' || true
import sys, importlib, platform
print("Python:", platform.python_version())
try:
    import torch
    print("Torch:", getattr(torch, "__version__", "unknown"))
except Exception as e:
    print("Torch probe failed:", e)
# Only safe ComfyUI modules to avoid CUDA noise
sys.path.insert(0, "/home/comfyuser/workspace/ComfyUI")
for m in ("folder_paths", "utils"):
    try:
        importlib.import_module(m)
        print(f"Imported {m} OK")
    except Exception as e:
        print(f"Import {m} failed:", e)
PY
}

# --- Strict core check (Python + Torch only) ---
check_python_core() {
  if [ ! -x "${PYTHON_EXEC}" ]; then log_error "Python not found at ${PYTHON_EXEC}"; return 1; fi
  "${PYTHON_EXEC}" - <<'PY'
import torch, sys
print(sys.executable)
print("torch:", getattr(torch, "__version__", "unknown"))
PY
}

# --- Decide ComfyUI flags based on GPU presence (pure; no logging) ---
decide_comfyui_flags() {
  local flags="${COMFYUI_FLAGS:-}" has_cuda
  has_cuda="$("${PYTHON_EXEC}" -c "import torch, sys; sys.stdout.write('1' if torch.cuda.is_available() else '0')" 2>/dev/null || echo "0")"
  [ "$has_cuda" = "0" ] && flags="$flags --cpu"
  echo "$flags"
}

# --- PHASE 1: File System Setup ---
setup_filesystem() {
  log "Preparing filesystem…"
  local dirs=(
    "${MODELS_DIR}/checkpoints" "${MODELS_DIR}/loras" "${MODELS_DIR}/vae" "${MODELS_DIR}/diffusers"
    "${DOWNLOADS_TMP}/checkpoints" "${DOWNLOADS_TMP}/loras" "${DOWNLOADS_TMP}/vae"
    "${DOWNLOADS_TMP}/huggingface" "${DOWNLOADS_TMP}/huggingface/.hf"
    "/home/comfyuser/workspace/input" "/home/comfyuser/workspace/output" "/home/comfyuser/workspace/debug"
  )
  mkdir -p "${dirs[@]}" || { log_error "Failed to create workspace dirs"; return 1; }
  chown -R comfyuser:comfyuser /home/comfyuser/workspace/ 2>/dev/null || true
  touch "${MODELS_DIR}/.catalyst_models" "${DOWNLOADS_TMP}/.catalyst_downloads" || true
  log "Filesystem ready"
  return 0
}

# --- PHASE 2: Security Initialization ---
security_init() {
  [ -f "${SCRIPTS_DIR}/network_security.sh" ] && bash "${SCRIPTS_DIR}/network_security.sh" || true
  return 0
}

# --- PHASE 3: Model Downloads ---
execute_downloads() {
  log "Download phase…"
  local has_downloads=false
  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_LORAS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && has_downloads=true
  $has_downloads || { log "No downloads configured"; return 0; }

  wait_for_network_ready 90 || { log_error "Network not ready for downloads (continuing)"; return 1; }
  [ -f "${SCRIPTS_DIR}/nexis_downloader.py" ] || { log_error "Downloader missing: ${SCRIPTS_DIR}/nexis_downloader.py"; return 1; }
  wait_for_path "${PYTHON_EXEC}" 10 && check_python_core || { log_error "Python core check failed"; return 1; }

  python_env_probe || true

  # Brief token sanity (info only)
  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && [ -z "${HUGGINGFACE_TOKEN:-}" ] && log "HF repos set; no HUGGINGFACE_TOKEN (private/gated may fail)"
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}${CIVITAI_LORAS_TO_DOWNLOAD:-}${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && [ -z "${CIVITAI_TOKEN:-}" ] && log "CivitAI models set; no CIVITAI_TOKEN (private/rate limits possible)"

  log "Starting downloads…"
  local download_timeout="${DOWNLOAD_TIMEOUT:-3600}" download_exit_code=0
  if timeout "${download_timeout}" "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"; then
    log "Downloads finished"
  else
    download_exit_code=$?
    case $download_exit_code in
      124) log_error "Downloads timed out (${download_timeout}s)";;
      2)   log "Downloads finished with some failures";;
      *)   log "Downloads exited with code ${download_exit_code}";;
    esac
  fi

  if [ -d "$DOWNLOADS_TMP" ]; then
    local file_count; file_count=$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)
    log "Downloaded files in temp: $file_count"
  fi
  return 0
}

# --- PHASE 4: File Organization ---
organize_files() {
  [ -d "$DOWNLOADS_TMP" ] || { log "No downloads dir"; return 0; }
  local file_count; file_count=$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)
  [ "$file_count" -gt 0 ] || { log "No files to organize"; return 0; }

  [ -f "${SCRIPTS_DIR}/file_organizer.sh" ] || { log_error "Organizer missing: ${SCRIPTS_DIR}/file_organizer.sh"; return 1; }
  if bash "${SCRIPTS_DIR}/file_organizer.sh"; then
    log "Files organized"
    find "$DOWNLOADS_TMP" -type d -empty -delete 2>/dev/null || true
    [ -d "$DOWNLOADS_TMP" ] && [ "$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)" -eq 0 ] && rm -rf "$DOWNLOADS_TMP" || true
  else
    log_error "Organization failed (files may remain in downloads_tmp)"
    return 1
  fi
  return 0
}

# --- PHASE 5: Service Startup (main process) ---
start_services() {
  log "Starting services…"
  cd "${COMFYUI_DIR}" || { log_error "Cannot access ComfyUI dir: ${COMFYUI_DIR}"; return 1; }

  python_env_probe || true

  local comfyui_flags; comfyui_flags="$(decide_comfyui_flags 2>/dev/null)"; [ -n "$comfyui_flags" ] || comfyui_flags=""
  if [[ "$comfyui_flags" == *"--cpu"* ]]; then log "Running ComfyUI in CPU mode"; else log "Running ComfyUI with CUDA"; fi

  exec "${PYTHON_EXEC}" main.py --listen 0.0.0.0 --port 8188 ${comfyui_flags}
}

# --- Main ---
main() {
  log "Init…"
  setup_filesystem     || { log_error "FS setup failed"; exit 1; }
  security_init        || true
  execute_downloads    || log_debug "Download phase returned nonzero"
  organize_files       || log_debug "Organization phase returned nonzero"
  start_services
}

# --- Pre-start Validation ---
log "Pre-start validation…"
[ -d "${COMFYUI_DIR}" ] || { log_error "ComfyUI dir missing: ${COMFYUI_DIR}"; exit 1; }
[ -f "${PYTHON_EXEC}" ] || { log_error "Python missing: ${PYTHON_EXEC}"; exit 1; }
[ -d "${SCRIPTS_DIR}" ] || { log_error "Scripts dir missing: ${SCRIPTS_DIR}"; exit 1; }

log "Validation OK"
main
