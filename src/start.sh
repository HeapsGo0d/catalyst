#!/bin/bash
# ==================================================================================
# CATALYST STARTUP (RunPod / ComfyUI)
# - Enhanced network readiness checks
# - Safe Python/ComfyUI probe (no GPU requirement)
# - Auto CPU fallback when CUDA not available
# - Proper timing for downloads
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

# --- Network Readiness Check ---
wait_for_network_ready() {
  local timeout="${1:-90}"  # Increased timeout for container startup
  local max_attempts=$((timeout / 3))
  local attempt=0
  
  log "Checking network connectivity (timeout: ${timeout}s)..."
  
  while [ $attempt -lt $max_attempts ]; do
    local all_ready=true
    
    # Test basic connectivity first
    if ! curl -s --connect-timeout 5 --max-time 10 "https://8.8.8.8" >/dev/null 2>&1; then
      all_ready=false
    # Test DNS resolution
    elif ! curl -s --connect-timeout 5 --max-time 10 "https://google.com" >/dev/null 2>&1; then
      all_ready=false
    # Test specific services
    elif ! curl -s --connect-timeout 5 --max-time 10 "https://civitai.com" >/dev/null 2>&1; then
      all_ready=false
    elif ! curl -s --connect-timeout 5 --max-time 10 "https://huggingface.co" >/dev/null 2>&1; then
      all_ready=false
    fi
    
    if [ "$all_ready" = true ]; then
      log "✅ Network connectivity confirmed"
      return 0
    fi
    
    attempt=$((attempt + 1))
    log "Network not ready, attempt $attempt/$max_attempts (waiting 3s)..."
    sleep 3
  done
  
  log_error "Network connectivity check failed after $max_attempts attempts"
  return 1
}

# --- Safe Python/ComfyUI probe (non-fatal; no import of main.py) ---
python_env_probe() {
  log "Running Python/ComfyUI probe..."
  "${PYTHON_EXEC}" - <<'PY' || true
import sys, importlib, platform
print("Executable:", sys.executable)
print("Python:", platform.python_version())
try:
    import torch
    print("Torch:", getattr(torch, "__version__", "unknown"))
    print("CUDA available:", torch.cuda.is_available())
except Exception as e:
    print("Torch probe failed:", e)

# Probe lightweight ComfyUI modules only (avoid main.py which may touch CUDA)
sys.path.insert(0, "/home/comfyuser/workspace/ComfyUI")
for m in ("folder_paths", "execution", "utils"):
    try:
        importlib.import_module(m)
        print(f"Imported {m} OK")
    except Exception as e:
        print(f"Import {m} failed:", e)
PY
}

# --- Strict core check (Python + Torch only) ---
check_python_core() {
  log "Verifying Python + Torch..."
  if [ ! -x "${PYTHON_EXEC}" ]; then
    log_error "Python executable not found or not executable at ${PYTHON_EXEC}"
    return 1
  fi
  "${PYTHON_EXEC}" - <<'PY'
import torch, sys
print(sys.executable)
print("torch:", getattr(torch, "__version__", "unknown"))
# do not require CUDA=True; just ensure torch imports
PY
}

# --- Decide ComfyUI flags based on GPU presence ---
decide_comfyui_flags() {
  local flags="${COMFYUI_FLAGS:-}"
  local has_cuda
  
  # Check CUDA availability without logging inside command substitution
  has_cuda="$("${PYTHON_EXEC}" -c "import torch, sys; sys.stdout.write('1' if torch.cuda.is_available() else '0')" 2>/dev/null || echo "0")"
  
  if [ "$has_cuda" = "0" ]; then
    log "No CUDA detected; forcing CPU mode (--cpu)."
    flags="$flags --cpu"
  else
    log "CUDA detected; running with GPU."
  fi
  
  # Return the flags (don't echo log messages here!)
  echo "$flags"
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
  
  # Fix ownership check - don't fail if we can't chown (common in containers)
  if chown -R comfyuser:comfyuser /home/comfyuser/workspace/ 2>/dev/null; then
    log "Set ownership on workspace directories"
  else
    log "Non-root; skipping workspace chown (likely bind-mounted/readonly)."
  fi
  
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
  
  # Check for download configuration
  local has_downloads=false
  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_LORAS_TO_DOWNLOAD:-}" ] && has_downloads=true
  [ -n "${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && has_downloads=true
  
  if [ "${has_downloads}" = false ]; then
    log "No downloads configured, skipping download phase"
    return 0
  fi
  
  # *** CRITICAL: Wait for network readiness ***
  if ! wait_for_network_ready 90; then
    log_error "Network not ready for downloads"
    log "Continuing with container startup without downloads..."
    return 1
  fi
  
  # Check required files and tools
  if [ ! -f "${SCRIPTS_DIR}/nexis_downloader.py" ]; then
    log_error "Download manager not found: ${SCRIPTS_DIR}/nexis_downloader.py"
    return 1
  fi
  
  if ! wait_for_path "${PYTHON_EXEC}" 10 || ! check_python_core; then
    log_error "Python core check failed"
    return 1
  fi
  
  # Show environment probe (non-fatal)
  python_env_probe || true
  
  # *** ENHANCED: Token validation before downloads ***
  log "Validating API tokens..."
  local token_issues=0
  
  if [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && [ -z "${HUGGINGFACE_TOKEN:-}" ]; then
    log "⚠️ HuggingFace repos configured but no HUGGINGFACE_TOKEN provided"
    log "   This may fail for private/gated repositories like FLUX.1-dev"
    ((token_issues++))
  fi
  
  if [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}${CIVITAI_LORAS_TO_DOWNLOAD:-}${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && [ -z "${CIVITAI_TOKEN:-}" ]; then
    log "⚠️ CivitAI models configured but no CIVITAI_TOKEN provided"
    log "   This may fail for private models or hit rate limits"
    ((token_issues++))
  fi
  
  if [ $token_issues -gt 0 ]; then
    log "Found $token_issues potential token issues. Continuing anyway..."
  fi

  log "Starting download manager…"
  local download_timeout="${DOWNLOAD_TIMEOUT:-3600}"
  
  # Run downloads with timeout and proper error handling
  local download_exit_code=0
  if timeout "${download_timeout}" "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"; then
    log "✅ Downloads completed successfully"
  else
    download_exit_code=$?
    if [ $download_exit_code -eq 124 ]; then
      log_error "Downloads timed out after ${download_timeout}s"
    elif [ $download_exit_code -eq 2 ]; then
      log "Downloads completed with some failures"
    else
      log "Downloads exited with code: $download_exit_code"
    fi
    log "Continuing with startup anyway…"
  fi

  # Report download results
  if [ -d "$DOWNLOADS_TMP" ]; then
    local file_count
    file_count=$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)
    log "Found $file_count downloaded files in temporary directory"
    
    if [ "$file_count" -gt 0 ]; then
      log "Downloads appear to have succeeded despite any errors"
    else
      log "No files downloaded - check logs for issues"
    fi
  else
    log "No downloads directory found - downloads may have failed completely"
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
  file_count=$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)
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
    organized_files=$(find "$MODELS_DIR" -type f 2>/dev/null | wc -l || echo 0)
    log "Total files in models directory: $organized_files"
    if [ -d "$DOWNLOADS_TMP" ]; then
      find "$DOWNLOADS_TMP" -type d -empty -delete 2>/dev/null || true
      if [ -d "$DOWNLOADS_TMP" ] && [ "$(find "$DOWNLOADS_TMP" -type f 2>/dev/null | wc -l || echo 0)" -eq 0 ]; then
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

  # Non-fatal probe (prints diagnostics but avoids importing main.py)
  python_env_probe || true

  # Get ComfyUI flags - FIXED: proper variable assignment
  local comfyui_flags
  comfyui_flags="$(decide_comfyui_flags)"
  
  log "Starting ComfyUI server with flags: ${comfyui_flags}"
  log "Launching ComfyUI…"
  
  # Execute ComfyUI with proper flag handling
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