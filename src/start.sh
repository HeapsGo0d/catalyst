#!/bin/bash
# ==================================================================================
# CATALYST STARTUP (RunPod / ComfyUI) — with GPU diagnostics and ownership fix
# - Root ownership fix for volume mount permissions
# - Comprehensive GPU diagnostics
# - Network readiness checks
# - Safe Python probe (no GPU touch during setup)
# - Idempotent downloads (no re-download on restart)
# ==================================================================================

set -Eeuo pipefail

# --- CRITICAL: Fix CUDA visibility issues ---
# CUDA_VISIBLE_DEVICES=all is invalid and hides GPUs from PyTorch
# Let nvidia-container-runtime handle device exposure via NVIDIA_VISIBLE_DEVICES
unset CUDA_VISIBLE_DEVICES 2>/dev/null || true

# --- CRITICAL: Root ownership fix for volume mounts ---
# If running as root, fix ownership then re-exec as comfyuser
if [ "$(id -u)" -eq 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] Running as root - fixing workspace ownership..."
  
  # Create critical directories with correct ownership
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/temp"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/workflows"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/models"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/settings"
  
  # Fix ownership recursively
  chown -R comfyuser:comfyuser "/home/comfyuser/workspace"
  
  # Validation logging
  echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] Ownership validation:"
  ls -ld /home/comfyuser/workspace/ComfyUI /home/comfyuser/workspace/ComfyUI/temp || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] Container UIDs: $(id -u):$(id -g)"
  
  echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] ✅ Ownership fixed - dropping privileges and re-executing as comfyuser..."
  exec gosu comfyuser "$0" "$@"
fi

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

# --- Make DEBUG_MODE control global verbosity ---
if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
  LOG_LEVEL=debug
  export DEBUG_MODE=true
fi

# --- Root Ownership Fix Function ---
fix_workspace_ownership() {
  log "Fixing workspace ownership (running as root)..."
  
  # Ensure critical directories exist first
  mkdir -p /home/comfyuser/workspace/ComfyUI/temp
  mkdir -p /home/comfyuser/workspace/ComfyUI/user/default/{workflows,models,settings}
  mkdir -p /home/comfyuser/workspace/ComfyUI/models/{checkpoints,loras,vae,diffusers}
  mkdir -p /home/comfyuser/workspace/{models,input,output,debug}
  mkdir -p /home/comfyuser/workspace/downloads_tmp/huggingface/.hf
  
  # Fix ownership recursively
  chown -R 1000:1000 /home/comfyuser/workspace/
  chown -R 1000:1000 /opt/venv/
  
  # Set proper permissions
  chmod -R u+rwX /home/comfyuser/workspace/ComfyUI/
  chmod -R u+rwX /home/comfyuser/workspace/models/
  chmod -R u+rwX /home/comfyuser/workspace/input/
  chmod -R u+rwX /home/comfyuser/workspace/output/
  
  # Verify critical paths are writable
  local critical_paths=(
    "/home/comfyuser/workspace/ComfyUI"
    "/home/comfyuser/workspace/ComfyUI/temp"
    "/home/comfyuser/workspace/ComfyUI/user"
  )
  
  for path in "${critical_paths[@]}"; do
    if [[ ! -w "$path" ]]; then
      log_error "CRITICAL: Path not writable after ownership fix: $path"
      exit 1
    fi
  done
  
  log "✅ Workspace ownership fixed and verified"
}

# --- Check if we need to run ownership fix ---
needs_ownership_fix() {
  # If running as root and workspace exists but isn't owned by comfyuser
  if [[ "$(id -u)" -eq 0 ]] && [[ -d /home/comfyuser/workspace ]]; then
    local workspace_owner
    workspace_owner=$(stat -c '%u' /home/comfyuser/workspace 2>/dev/null || echo "unknown")
    if [[ "$workspace_owner" != "1000" ]]; then
      return 0  # needs fix
    fi
    
    # Also check if ComfyUI temp dir is writable by comfyuser
    if [[ -d "$COMFYUI_DIR" ]] && [[ ! -w "$COMFYUI_DIR" ]]; then
      return 0  # needs fix
    fi
  fi
  
  return 1  # no fix needed
}

# --- Drop to comfyuser and re-exec ---
drop_privileges_and_reexec() {
  log "Dropping privileges and re-executing as comfyuser..."
  
  # Install gosu if not present (shouldn't be needed in our image)
  if ! command -v gosu >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq gosu
  fi
  
  # Re-execute this script as comfyuser
  exec gosu comfyuser "$0" "$@"
}

# --- GPU Diagnostics ---
gpu_diagnostics() {
  log "=== GPU DIAGNOSTICS ==="
  
  # Check GPU devices
  log "[GPU DEBUG] GPU Devices:"
  if ls -l /dev/nvidia* 2>/dev/null; then
    log "✅ NVIDIA devices found"
  else
    log "❌ No NVIDIA devices found in /dev/"
  fi
  
  # Check nvidia-smi
  log "[GPU DEBUG] nvidia-smi output:"
  if nvidia-smi 2>/dev/null; then
    log "✅ nvidia-smi succeeded"
  else
    log "❌ nvidia-smi failed or not available"
  fi
  
  # Check CUDA libraries
  log "[GPU DEBUG] CUDA Libraries:"
  if ldconfig -p | grep libcuda; then
    log "✅ CUDA libraries found"
  else
    log "❌ CUDA libraries not found"
  fi
  
  # Check PyTorch CUDA
  log "[GPU DEBUG] PyTorch CUDA Status:"
  "${PYTHON_EXEC}" - <<'PY'
import torch
import os
print(f"torch.cuda.is_available(): {torch.cuda.is_available()}")
print(f"torch.cuda.device_count(): {torch.cuda.device_count()}")
print(f"CUDA_VISIBLE_DEVICES: {os.getenv('CUDA_VISIBLE_DEVICES', 'not set')}")
print(f"torch.version.cuda: {torch.version.cuda}")
if torch.cuda.is_available():
    print(f"GPU 0 name: {torch.cuda.get_device_name(0)}")
    print(f"GPU 0 memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
else:
    print("No CUDA devices available to PyTorch")

# Test CUDA library loading
try:
    import ctypes
    ctypes.CDLL('libcuda.so.1')
    print("✅ libcuda.so.1 loaded successfully")
except Exception as e:
    print(f"❌ Failed to load libcuda.so.1: {e}")
PY
  
  log "=== END GPU DIAGNOSTICS ==="
}

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
  local path="$1"
  local tmo="${2:-30}"
  local counter=0
  while [ ! -e "$path" ] && [ $counter -lt $tmo ]; do
    sleep 1
    counter=$((counter + 1))
  done
  if [ ! -e "$path" ]; then
    log_error "Timeout waiting for path: $path"
    return 1
  fi
  return 0
}

# --- Network Readiness Check ---
wait_for_network_ready() {
  local tmo="${1:-90}"
  local max_attempts=$(( tmo / 3 ))
  local attempt=0
  log "Checking network… (timeout ${tmo}s)"
  while [ $attempt -lt $max_attempts ]; do
    if curl -s --connect-timeout 5 --max-time 10 https://8.8.8.8 >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://google.com >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://civitai.com >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://huggingface.co >/dev/null 2>&1; then
      log "Network OK"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 3
  done
  log_error "Network check failed"
  return 1
}

# --- Safe Python/ComfyUI probe (no GPU-touching imports during setup) ---
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
# Only safe ComfyUI modules to avoid CUDA noise during setup
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

# --- Check CUDA availability (separate from flag building) ---
check_cuda_availability() {
  local has_cuda
  has_cuda="$("${PYTHON_EXEC}" -c "import torch; print('1' if torch.cuda.is_available() else '0')" 2>/dev/null || echo "0")"
  
  if [ "$has_cuda" = "1" ]; then
    log "✅ CUDA available - ComfyUI will use GPU"
    return 0
  else
    log "❌ CUDA not available - forcing CPU mode"
    return 1
  fi
}

# --- PHASE 1: File System Setup ---
setup_filesystem() {
  log "Preparing filesystem…"
  local dirs=(
    "${MODELS_DIR}/checkpoints" "${MODELS_DIR}/loras" "${MODELS_DIR}/vae" "${MODELS_DIR}/diffusers" "${MODELS_DIR}/huggingface"
    "${DOWNLOADS_TMP}/huggingface/.hf"
    "/home/comfyuser/workspace/input" "/home/comfyuser/workspace/output" "/home/comfyuser/workspace/debug"
  )
  mkdir -p "${dirs[@]}" || { log_error "Failed to create workspace dirs"; return 1; }
  touch "${MODELS_DIR}/.catalyst_models" "${DOWNLOADS_TMP}/.catalyst_downloads" || true
  
  log "Filesystem ready"
  return 0
}

# --- PHASE 2: Security Initialization ---
security_init() {
  [ -f "${SCRIPTS_DIR}/network_security.sh" ] && bash "${SCRIPTS_DIR}/network_security.sh" || true
  return 0
}

# --- PHASE 3: Model Downloads (Idempotent) ---
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

  [[ "${DEBUG_MODE:-false}" == "true" ]] && python_env_probe || true

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

  # Show download summary
  if [ -d "$MODELS_DIR" ]; then
    local checkpoints; checkpoints=$(find "$MODELS_DIR/checkpoints" -type f 2>/dev/null | wc -l || echo 0)
    local loras; loras=$(find "$MODELS_DIR/loras" -type f 2>/dev/null | wc -l || echo 0)
    local vaes; vaes=$(find "$MODELS_DIR/vae" -type f 2>/dev/null | wc -l || echo 0)
    local hf_models; hf_models=$(find "$MODELS_DIR/huggingface" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
    log "Model summary: $checkpoints checkpoints, $loras LoRAs, $vaes VAEs, $hf_models HF models"
  fi
  
  return 0
}

# --- PHASE 4: Service Startup (main process) ---
start_services() {
  log "Starting services…"
  cd "${COMFYUI_DIR}" || { log_error "Cannot access ComfyUI dir: ${COMFYUI_DIR}"; return 1; }

  [[ "${DEBUG_MODE:-false}" == "true" ]] && python_env_probe || true

  # Run GPU diagnostics
  gpu_diagnostics
  
  # Build ComfyUI command args as array (no command substitution!)
  local args=(main.py --listen 0.0.0.0 --port 8188)
  
  # Add base flags from environment
  if [ -n "${COMFYUI_FLAGS:-}" ]; then
    # Split COMFYUI_FLAGS and add to args
    read -ra flag_array <<< "${COMFYUI_FLAGS}"
    args+=("${flag_array[@]}")
  fi
  
  # Check CUDA and add --cpu if needed
  if ! check_cuda_availability; then
    args+=(--cpu)
    log "⚠️ Running ComfyUI in CPU mode"
  else
    log "🚀 Running ComfyUI with GPU acceleration"
  fi

  # Execute ComfyUI with clean argument array
  exec "${PYTHON_EXEC}" "${args[@]}"
}

# --- Main Execution Flow ---
main() {
  log "Catalyst startup beginning..."
  
  # Check if we need to fix ownership as root
  if needs_ownership_fix; then
    fix_workspace_ownership
    drop_privileges_and_reexec "$@"
    # This line should never be reached
    exit 1
  fi
  
  # Now running as comfyuser - proceed with normal startup
  log "Running as user: $(whoami) (UID: $(id -u))"
  
  setup_filesystem     || { log_error "FS setup failed"; exit 1; }
  security_init        || true
  execute_downloads    || log_debug "Download phase returned nonzero"
  start_services
}

# --- Pre-start Validation ---
log "=== CATALYST STARTUP ==="
log "Pre-start validation…"
[ -d "${COMFYUI_DIR}" ] || { log_error "ComfyUI dir missing: ${COMFYUI_DIR}"; exit 1; }
[ -f "${PYTHON_EXEC}" ] || { log_error "Python missing: ${PYTHON_EXEC}"; exit 1; }
[ -d "${SCRIPTS_DIR}" ] || { log_error "Scripts dir missing: ${SCRIPTS_DIR}"; exit 1; }

log "✅ Validation passed"
main "$@"