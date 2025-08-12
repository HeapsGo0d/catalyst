#!/bin/bash
# ==================================================================================
# CATALYST STARTUP (RunPod / ComfyUI)
# - Root → fix ownership of mounted volume, then drop to comfyuser (gosu)
# - GPU diagnostics (safe; not injected into exec args)
# - Network readiness + safe Python probe
# - Idempotent downloads with fingerprinted completion marker
# ==================================================================================

set -Eeuo pipefail
umask 002

# --- CUDA visibility: let nvidia-container-runtime expose devices
unset CUDA_VISIBLE_DEVICES 2>/dev/null || true

# --- If running as root, repair ownership of mounted paths, then re-exec as comfyuser
if [ "$(id -u)" -eq 0 ]; then
  ts() { date '+%Y-%m-%d %H:%M:%S'; }
  echo "$(ts) [STARTUP] Running as root - fixing workspace ownership..."

  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/temp"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/workflows"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/models"
  install -d -m 0770 -o comfyuser -g comfyuser "/home/comfyuser/workspace/ComfyUI/user/default/settings"

  chown -R comfyuser:comfyuser "/home/comfyuser/workspace"

  echo "$(ts) [STARTUP] Ownership validation:"
  ls -ld /home/comfyuser/workspace/ComfyUI /home/comfyuser/workspace/ComfyUI/temp || true
  echo "$(ts) [STARTUP] ✅ Ownership fixed - dropping privileges and re-executing as comfyuser..."
  exec gosu comfyuser "$0" "$@"
fi

# --- Paths / env
LOG_PREFIX="[STARTUP]"
COMFYUI_DIR="/home/comfyuser/workspace/ComfyUI"
PYTHON_EXEC="/opt/venv/bin/python"
SCRIPTS_DIR="/home/comfyuser/scripts"
STARTUP_ERROR_LOG="/home/comfyuser/workspace/startup_errors.log"
MODELS_DIR="/home/comfyuser/workspace/models"
DOWNLOADS_TMP="/home/comfyuser/workspace/downloads_tmp" # kept for HF cache

export PATH="/opt/venv/bin:${PATH}"
export PYTHONNOUSERSITE=1
export HF_HOME="/home/comfyuser/workspace/downloads_tmp/huggingface/.hf"
: "${SECURITY_TOKEN_VAULT_PATH:=/run/secrets/token}"
: "${DOWNLOAD_TIMEOUT:=3600}"

# --- Logging
: "${LOG_LEVEL:=info}"
log()       { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
log_debug() { [ "${LOG_LEVEL}" = "debug" ] && log "[debug] $*"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} [ERROR] $*" | tee -a "${STARTUP_ERROR_LOG}"; }

# --- Global DEBUG
if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
  LOG_LEVEL=debug
  export DEBUG_MODE=true
fi

# --- Signals
term_handler() {
  log "SIGTERM received. Shutting down…"
  jobs -p | xargs -r kill || true
  wait || true
  log "Services stopped."
  exit 0
}
trap 'kill ${!} 2>/dev/null || true; term_handler' SIGTERM

# --- Helpers
wait_for_path() {
  local path="$1" tmo="${2:-30}" c=0
  while [ ! -e "$path" ] && [ $c -lt $tmo ]; do sleep 1; c=$((c+1)); done
  [ -e "$path" ] || { log_error "Timeout waiting for path: $path"; return 1; }
}

wait_for_network_ready() {
  local tmo="${1:-90}" tries=$(( tmo / 3 )) n=0
  log "Checking network… (timeout ${tmo}s)"
  while [ $n -lt $tries ]; do
    if curl -s --connect-timeout 5 --max-time 10 https://8.8.8.8 >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://google.com >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://civitai.com >/dev/null 2>&1 \
      && curl -s --connect-timeout 5 --max-time 10 https://huggingface.co >/dev/null 2>&1
    then
      log "Network OK"; return 0
    fi
    n=$((n+1)); sleep 3
  done
  log_error "Network check failed"; return 1
}

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
sys.path.insert(0, "/home/comfyuser/workspace/ComfyUI")
for m in ("folder_paths", "utils"):
    try:
        importlib.import_module(m)
        print(f"Imported {m} OK")
    except Exception as e:
        print(f"Import {m} failed:", e)
PY
}

check_python_core() {
  [ -x "${PYTHON_EXEC}" ] || { log_error "Python not found at ${PYTHON_EXEC}"; return 1; }
  "${PYTHON_EXEC}" - <<'PY'
import torch, sys
print(sys.executable)
print("torch:", getattr(torch, "__version__", "unknown"))
PY
}

check_cuda_availability() {
  local has_cuda
  has_cuda="$("${PYTHON_EXEC}" -c "import torch; print('1' if torch.cuda.is_available() else '0')" 2>/dev/null || echo "0")"
  if [ "$has_cuda" = "1" ]; then log "✅ CUDA available - ComfyUI will use GPU"; return 0;
  else log "❌ CUDA not available - forcing CPU mode"; return 1; fi
}

gpu_diagnostics() {
  log "=== GPU DIAGNOSTICS ==="
  log "[GPU DEBUG] Devices:"; ls -l /dev/nvidia* 2>/dev/null || true
  log "[GPU DEBUG] nvidia-smi:"; nvidia-smi || log "[GPU DEBUG] nvidia-smi not available"
  log "[GPU DEBUG] CUDA libs:"; ldconfig -p | grep -E 'libcuda\.so|libnvidia' || true
  log "[GPU DEBUG] PyTorch CUDA:"
  "${PYTHON_EXEC}" - <<'PY'
import torch, os, ctypes
print("cuda.is_available:", torch.cuda.is_available())
print("cuda.device_count:", torch.cuda.device_count())
print("CUDA_VISIBLE_DEVICES:", os.getenv("CUDA_VISIBLE_DEVICES"))
print("torch.version.cuda:", torch.version.cuda)
if torch.cuda.is_available():
    print("device0:", torch.cuda.get_device_name(0))
try:
    ctypes.CDLL('libcuda.so.1'); print("libcuda.so.1 loaded OK")
except Exception as e:
    print("libcuda load failed:", e)
PY
  log "=== END GPU DIAGNOSTICS ==="
}

# --- PHASE 1: Filesystem
setup_filesystem() {
  log "Preparing filesystem…"
  local dirs=(
    "${MODELS_DIR}/checkpoints" "${MODELS_DIR}/loras" "${MODELS_DIR}/vae" "${MODELS_DIR}/diffusers" "${MODELS_DIR}/huggingface"
    "${DOWNLOADS_TMP}/huggingface/.hf"
    "/home/comfyuser/workspace/input" "/home/comfyuser/workspace/output" "/home/comfyuser/workspace/debug"
  )
  mkdir -p "${dirs[@]}" || { log_error "Failed to create workspace dirs"; return 1; }
  touch "${MODELS_DIR}/.catalyst_models" || true
  log "Filesystem ready"
}

# --- PHASE 2: Security init (optional hook)
security_init() {
  [ -f "${SCRIPTS_DIR}/network_security.sh" ] && bash "${SCRIPTS_DIR}/network_security.sh" || true
}

# --- PHASE 3: Downloads (idempotent with fingerprint)
execute_downloads() {
  log "Download phase…"
  local has_dl=false
  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && has_dl=true
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" ] && has_dl=true
  [ -n "${CIVITAI_LORAS_TO_DOWNLOAD:-}" ] && has_dl=true
  [ -n "${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && has_dl=true
  $has_dl || { log "No downloads configured"; return 0; }

  local MARKER="${MODELS_DIR}/.catalyst_downloads_complete"
  local FPR
  FPR="$(printf '%s\n' \
    "${HF_REPOS_TO_DOWNLOAD:-}" \
    "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" \
    "${CIVITAI_LORAS_TO_DOWNLOAD:-}" \
    "${CIVITAI_VAES_TO_DOWNLOAD:-}" \
    | sha256sum | awk '{print $1}')"

  if [[ -f "$MARKER" ]] && grep -q "$FPR" "$MARKER"; then
    log "✅ Found completion marker (fingerprint match) — skipping downloads."
    return 0
  fi

  wait_for_network_ready 90 || { log_error "Network not ready for downloads (continuing)"; return 1; }
  [ -f "${SCRIPTS_DIR}/nexis_downloader.py" ] || { log_error "Downloader missing: ${SCRIPTS_DIR}/nexis_downloader.py"; return 1; }
  wait_for_path "${PYTHON_EXEC}" 10 && check_python_core || { log_error "Python core check failed"; return 1; }
  [[ "${DEBUG_MODE:-false}" == "true" ]] && python_env_probe || true

  [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && [ -z "${HUGGINGFACE_TOKEN:-}" ] && log "HF repos set; no HUGGINGFACE_TOKEN (private/gated may fail)"
  [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}${CIVITAI_LORAS_TO_DOWNLOAD:-}${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && [ -z "${CIVITAI_TOKEN:-}" ] && log "CivitAI models set; no CIVITAI_TOKEN (private/rate limits possible)"

  log "▶️  Running downloads (fingerprint changed or no marker)…"
  local SENT="${MODELS_DIR}/.catalyst_downloading"
  : > "$SENT"
  trap 'rm -f "$SENT"' EXIT

  if timeout "${DOWNLOAD_TIMEOUT}" "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"; then
    printf 'fingerprint=%s\ntimestamp=%s\n' "$FPR" "$(date -Iseconds)" > "$MARKER"
    rm -f "$SENT"
    log "✅ Downloads complete; marker updated."
  else
    rm -f "$SENT" "$MARKER"
    log_error "Downloads failed — marker cleared."
    return 1
  fi

  # Quick summary
  if [ -d "$MODELS_DIR" ]; then
    local cp=$(find "$MODELS_DIR/checkpoints" -type f 2>/dev/null | wc -l || echo 0)
    local lr=$(find "$MODELS_DIR/loras" -type f 2>/dev/null | wc -l || echo 0)
    local va=$(find "$MODELS_DIR/vae" -type f 2>/dev/null | wc -l || echo 0)
    local hf=$(find "$MODELS_DIR/huggingface" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
    log "Model summary: $cp checkpoints, $lr LoRAs, $va VAEs, $hf HF repos"
  fi
}

# --- PHASE 4: Start services (ComfyUI)
start_services() {
  log "Starting services…"
  cd "${COMFYUI_DIR}" || { log_error "Cannot access ComfyUI dir: ${COMFYUI_DIR}"; return 1; }

  [[ "${DEBUG_MODE:-false}" == "true" ]] && python_env_probe || true
  gpu_diagnostics

  # Build clean args array
  local args=(main.py --listen 0.0.0.0 --port 8188)
  if [ -n "${COMFYUI_FLAGS:-}" ]; then
    read -ra extra <<< "${COMFYUI_FLAGS}"
    args+=("${extra[@]}")
  fi

  if ! check_cuda_availability; then
    args+=(--cpu)
    log "⚠️ Running ComfyUI in CPU mode"
  else
    log "🚀 Running ComfyUI with GPU acceleration"
  fi

  exec "${PYTHON_EXEC}" "${args[@]}"
}

# --- Main
main() {
  log "Catalyst startup beginning..."
  log "Running as user: $(whoami) (UID: $(id -u))"

  # Ensure base workspace structure
  mkdir -p "$MODELS_DIR" "$DOWNLOADS_TMP/huggingface/.hf" || true

  setup_filesystem     || { log_error "FS setup failed"; exit 1; }
  security_init        || true
  execute_downloads    || log_debug "Download phase returned nonzero"
  start_services
}

# --- Pre-start validation
log "=== CATALYST STARTUP ==="
log "Pre-start validation…"
[ -d "${COMFYUI_DIR}" ] || { log_error "ComfyUI dir missing: ${COMFYUI_DIR}"; exit 1; }
[ -f "${PYTHON_EXEC}" ] || { log_error "Python missing: ${PYTHON_EXEC}"; exit 1; }
[ -d "${SCRIPTS_DIR}" ] || { log_error "Scripts dir missing: ${SCRIPTS_DIR}"; exit 1; }
log "✅ Validation passed"

main "$@"
