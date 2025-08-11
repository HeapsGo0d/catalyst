#!/bin/bash
# ==================================================================================
# CATALYST STARTUP (RunPod / ComfyUI)
# - Unified Python/ComfyUI env checks
# - Correct phase numbering
# - Rich diagnostics; keep-on-start for noncritical phases
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

# Default secret location if not provided at runtime
: "${SECURITY_TOKEN_VAULT_PATH:=/run/secrets/token}"

# --- Logging ---
log()       { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} [ERROR] $*" | tee -a "${STARTUP_ERROR_LOG}"; }

# --- Signal Handling for Graceful Shutdown ---
term_handler() {
  log "SIGTERM received. Shutting down services gracefully..."
  jobs -p | xargs -r kill || true
  wait || true
  log "All services have been shut down."
  exit 0
}
trap 'kill ${!} 2>/dev/null || true; term_handler' SIGTERM

# --- Wait Helpers ---
wait_for_path() {
  local path="$1"; local timeout="${2:-30}"; local counter=0
  log "Waiting for path: $path"
  while [ ! -e "$path" ] && [ $counter -lt $timeout ]; do
    sleep 1; counter=$((counter + 1))
  done
  if [ ! -e "$path" ]; then log_error "Timeout waiting for path: $path"; return 1; fi
  log "Path ready: $path"; return 0
}

wait_for_service() {
  local service_url="$1"; local timeout="${2:-60}"; local counter=0
  log "Waiting for service: $service_url"
  while ! curl -fs "$service_url" >/dev/null 2>&1 && [ $counter -lt $timeout ]; do
    sleep 2; counter=$((counter + 2))
  done
  if [ $counter -ge $timeout ]; then log_error "Timeout waiting for service: $service_url"; return 1; fi
  log "Service is responding: $service_url"; return 0
}

# --- Python/ComfyUI Environment Check ---
check_python_env() {
  log "Running Python/ComfyUI environment check..."
  if [ ! -x "${PYTHON_EXEC}" ]; then
    log_error "Python executable not found or not executable at ${PYTHON_EXEC}"
    return 1
  fi

  # Interpreter + torch diagnostics
  if ! "${PYTHON_EXEC}" - <<'PY'
import sys
print("Executable:", sys.executable)
print("Version:", sys.version.split()[0])
try:
    import torch
    print("Torch:", getattr(torch, "__version__", "unknown"))
    print("CUDA available:", getattr(torch, "cuda", None) and torch.cuda.is_available())
except Exception as e:
    print("Torch import failed:", e)
    raise
PY
  then
    log_error "Python environment test failed (torch import)"
    return 1
  fi

  # ComfyUI importability (explicit path)
  if ! "${PYTHON_EXEC}" - <<PY
import sys
sys.path.insert(0, "${COMFYUI_DIR}")
try:
    import main, folder_paths
    print("ComfyUI modules importable")
except Exception as e:
    print("ComfyUI import test failed:", e)
    raise
PY
  then
    log_error "Python environment test failed (ComfyUI import)"
    return 1
  fi

  log "✅ Python/ComfyUI environment OK"
  return 0
}

# --- PHASE 1: File System Setup ---
setup_filesystem() {
  log "=== PHASE 1: File System Setup ==="

  local dirs=(
    "${MODELS_DIR}/checkpoints"
    "${MODELS_DIR}/loras"
    "${MODELS_DIR}/vae"
    "${MODELS_DIR}/diffusers"
    "${DOWNLOADS_TMP}/checkpoints"
    "${DOWNLOADS_TMP}/loras"
    "${DOWNLOADS_TMP}/vae"
    "${DOWNLOADS_TMP}/huggingface"
    "/home/comfyuser/workspace/input"
    "/home/comfyuser/workspace/output"
    "/home/comfyuser/workspace/debug"
  )

  for d in "${dirs[@]}"; do
    mkdir -p "$d" || { log_error "Failed to create directory: $d"; return 1; }
    log "Ensured directory: $d"
  done

  chown -R comfyuser:comfyuser /home/comfyuser/workspace/ || {
    log_error "Failed to set ownership on /home/comfyuser/workspace"; return 1;
  }

  touch "${MODELS_DIR}/.catalyst_models" "${DOWNLOADS_TMP}/.catalyst_downloads" || true

  log "✅ File system setup completed"
  return 0
}

# --- PHASE 2: Security Initialization ---
security_init() {
  log "=== PHASE 2: Security Initialization ==="
  if [ -f "${SCRIPTS_DIR}/network_security.sh" ]; then
    bash "${SCRIPTS_DIR}/network_security.sh" || log "network_security.sh returned nonzero (continuing)"
  else
    log "Warning: network_security.sh not found, skipping…"
  fi
  return 0
}

# --- PHASE 3: Model Downloads ---
execute_downloads() {
  log "=== PHASE 3: Model Downloads ==="

  # Check if any downloads are configured
  local has_downloads=false
  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_LORAS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && has_downloads=true

  if [ "${has_downloads}" = false ]; then
    log "No downloads configured, skipping download phase"
    return 0
  fi

  # Ensure download manager exists
  if [ ! -f "${SCRIPTS_DIR}/nexis_downloader.py" ]; then
    log_error "Download manager not found: ${SCRIPTS_DIR}/nexis_downloader.py"
    return 1
  fi

  # Gate on Python readiness + ComfyUI importability
  if ! wait_for_path "${PYTHON_EXEC}" 10 || ! check_python_env; then
    log_error "Python environment test failed"
    return 1
  fi

  log "Starting download manager…"
  local download_timeout=3600 # seconds
  if timeout "${download_timeout}" "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"; then
    log "✅ Downloads completed successfully"
  else
    local exit_code=$?
    if [ $exit_code -eq 124 ]; then
      log_error "Downloads timed out after ${download_timeout}s"
      log "Continuing with startup anyway…"
    else
      log "Downloads exited with code: $exit_code"
      log "Continuing with startup anyway…"
    fi
  fi

  if [ -d "$DOWNLOADS_TMP" ]; then
    local file_count
    file_count=$(find "$DOWNLOADS_TMP" -type f | wc -l || echo 0)
    log "Found $file_count downloaded files in temporary directory"
  else
    log "No downloads directory found - downloads may have failed"
  fi

  return 0
}

# --- PHASE 4: File Organization ---
organize_files() {
  log "=== PHASE 4: File Organization ==="

  if [ ! -d "$DOWNLOADS_TMP" ]; then
    log "No downloads to organize, skipping"
    return 0
  fi
  local file_count
  file_count=$(find "$DOWNLOADS_TMP" -type f | wc -l || echo 0)
  if [ "$file_count" -eq 0 ]; then
    log "No files to organize, skipping"
    return 0
  fi

  log "Organizing $file_count downloaded files…"

  if [ ! -f "${SCRIPTS_DIR}/file_organizer.sh" ]; then
    log_error "File organizer not found: ${SCRIPTS_DIR}/file_organizer.sh"
    return 1
  fi

  if bash "${SCRIPTS_DIR}/file_organizer.sh"; then
    log "✅ File organization completed successfully"
    local organized_files
    organized_files=$(find "$MODELS_DIR" -type f | wc -l || echo 0)
    log "Total files in models directory: $organized_files"

    # Clean up empty folders in downloads_tmp
    if [ -d "$DOWNLOADS_TMP" ]; then
      find "$DOWNLOADS_TMP" -type d -empty -delete 2>/dev/null || true
      if [ -d "$DOWNLOADS_TMP" ] && [ "$(find "$DOWNLOADS_TMP" -type f | wc -l || echo 0)" -eq 0 ]; then
        log "Removing empty downloads directory"
        rm -rf "$DOWNLOADS_TMP" || true
      fi
    fi
  else
    log_error "File organization failed - files may still be in downloads_tmp"
    log "Check /home/comfyuser/workspace/debug/ for preserved files"
    return 1
  fi

  return 0
}

# --- PHASE 5: Service Startup (main process) ---
start_services() {
  log "=== PHASE 5: Service Startup ==="

  cd "${COMFYUI_DIR}" || { log_error "Cannot access ComfyUI dir: ${COMFYUI_DIR}"; return 1; }

  # Final sanity check
  if ! check_python_env; then
    log_error "ComfyUI Python environment test failed"
    return 1
  fi

  local comfyui_flags="${COMFYUI_FLAGS:-}"
  log "Starting ComfyUI server with flags: ${comfyui_flags}"
  log "Launching ComfyUI…"
  exec "${PYTHON_EXEC}" main.py --listen 0.0.0.0 --port 8188 ${comfyui_flags}
}

# --- Main ---
main() {
  log "🚀 Initializing Catalyst container startup sequence…"

  if ! setup_filesystem; then
    log_error "File system setup failed, aborting startup"
    exit 1
  fi

  security_init || log "Security init returned nonzero (continuing)"

  if ! execute_downloads; then
    log_error "Download phase failed, but continuing with startup…"
  fi

  if ! organize_files; then
    log_error "File organization failed, but continuing with startup…"
  fi

  start_services
}

# --- Pre-start Validation ---
log "Performing pre-startup validation…"

if [ ! -d "${COMFYUI_DIR}" ]; then
  log_error "ComfyUI directory not found at ${COMFYUI_DIR}. Aborting."
  exit 1
fi
if [ ! -f "${PYTHON_EXEC}" ]; then
  log_error "Python executable not found at ${PYTHON_EXEC}. Aborting."
  exit 1
fi
if [ ! -d "${SCRIPTS_DIR}" ]; then
  log_error "Scripts directory not found at ${SCRIPTS_DIR}. Aborting."
  exit 1
fi

log "✅ Pre-startup validation passed"
main
