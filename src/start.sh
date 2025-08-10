#!/bin/bash
# ==================================================================================
# CATALYST: ROBUST STARTUP SCRIPT WITH PROPER TIMING
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

# Default secret location if not provided at runtime
: "${SECURITY_TOKEN_VAULT_PATH:=/run/secrets/token}"

# Materialize secrets (if provided) into the tmpfs file
mkdir -p /run/secrets
if [ -n "${HUGGINGFACE_TOKEN:-}" ] || [ -n "${CIVITAI_TOKEN:-}" ]; then
    {
        [ -n "${HUGGINGFACE_TOKEN:-}" ] && echo "HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN}"
        [ -n "${CIVITAI_TOKEN:-}" ]     && echo "CIVITAI_TOKEN=${CIVITAI_TOKEN}"
    } > "${SECURITY_TOKEN_VAULT_PATH}"
    chmod 600 "${SECURITY_TOKEN_VAULT_PATH}"
fi

# --- Logging Functions ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $1"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} [ERROR] $1" | tee -a "${STARTUP_ERROR_LOG}"
}

# --- Signal Handling for Graceful Shutdown ---
trap 'kill ${!}; term_handler' SIGTERM
term_handler() {
    log "SIGTERM received. Shutting down services gracefully..."
    # Kill background processes
    jobs -p | xargs -r kill
    wait
    log "All services have been shut down."
    exit 0
}

# --- Wait Functions ---
wait_for_path() {
    local path="$1"
    local timeout="${2:-30}"
    local counter=0
    
    log "Waiting for path to be ready: $path"
    while [ ! -e "$path" ] && [ $counter -lt $timeout ]; do
        sleep 1
        counter=$((counter + 1))
    done
    
    if [ ! -e "$path" ]; then
        log_error "Timeout waiting for path: $path"
        return 1
    fi
    
    log "Path ready: $path"
    return 0
}

wait_for_service() {
    local service_url="$1"
    local timeout="${2:-60}"
    local counter=0
    
    log "Waiting for service to respond: $service_url"
    while ! curl -fs "$service_url" >/dev/null 2>&1 && [ $counter -lt $timeout ]; do
        sleep 2
        counter=$((counter + 2))
    done
    
    if [ $counter -ge $timeout ]; then
        log_error "Timeout waiting for service: $service_url"
        return 1
    fi
    
    log "Service is responding: $service_url"
    return 0
}

# --- File System Preparation ---
setup_filesystem() {
    log "=== PHASE 1: File System Setup ==="
    
    # Create all required directories with proper ownership
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
    
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir"; then
            log_error "Failed to create directory: $dir"
            return 1
        fi
        log "Created directory: $dir"
    done
    
    # Ensure proper permissions
    chown -R comfyuser:comfyuser /home/comfyuser/workspace/ || {
        log_error "Failed to set proper ownership on workspace"
        return 1
    }
    
    # Create safety marker files to prevent accidental deletion
    touch "${MODELS_DIR}/.catalyst_models" "${DOWNLOADS_TMP}/.catalyst_downloads"
    
    log "✅ File system setup completed"
    return 0
}

# --- Download Phase ---
execute_downloads() {
    log "=== PHASE 2: Model Downloads ==="
    
    # Check if any downloads are configured
    local has_downloads=false
    [ -n "${HF_REPOS_TO_DOWNLOAD:-}" ] && has_downloads=true
    [ -n "${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-}" ] && has_downloads=true
    [ -n "${CIVITAI_LORAS_TO_DOWNLOAD:-}" ] && has_downloads=true
    [ -n "${CIVITAI_VAES_TO_DOWNLOAD:-}" ] && has_downloads=true
    
    if [ "$has_downloads" = false ]; then
        log "No downloads configured, skipping download phase"
        return 0
    fi
    
    # Ensure download script exists
    if [ ! -f "${SCRIPTS_DIR}/nexis_downloader.py" ]; then
        log_error "Download manager not found: ${SCRIPTS_DIR}/nexis_downloader.py"
        return 1
    fi
    
    # Wait for Python to be fully ready
    if ! wait_for_path "${PYTHON_EXEC}" 10; then
        log_error "Python executable not ready"
        return 1
    fi
    
    # Test Python environment
    if ! "${PYTHON_EXEC}" -c "import sys; print('Python ready:', sys.version)" >/dev/null 2>&1; then
        log_error "Python environment test failed"
        return 1
    fi
    
    log "Starting download manager..."
    
    # Run download manager with timeout protection
    local download_timeout=3600  # 1 hour max for downloads
    
    if timeout "$download_timeout" "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"; then
        log "✅ Downloads completed successfully"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_error "Downloads timed out after ${download_timeout} seconds"
            log "Continuing with startup anyway..."
        else
            log "Downloads completed with exit code: $exit_code"
            log "Continuing with startup anyway..."
        fi
    fi
    
    # Verify downloads directory exists and has content
    if [ -d "$DOWNLOADS_TMP" ]; then
        local file_count=$(find "$DOWNLOADS_TMP" -type f | wc -l)
        log "Found $file_count downloaded files in temporary directory"
    else
        log "No downloads directory found - downloads may have failed"
    fi
    
    return 0
}

# --- File Organization Phase ---
organize_files() {
    log "=== PHASE 3: File Organization ==="
    
    # Only run organization if downloads directory exists and has files
    if [ ! -d "$DOWNLOADS_TMP" ]; then
        log "No downloads to organize, skipping file organization"
        return 0
    fi
    
    local file_count=$(find "$DOWNLOADS_TMP" -type f | wc -l)
    if [ $file_count -eq 0 ]; then
        log "No files to organize, skipping file organization"
        return 0
    fi
    
    log "Organizing $file_count downloaded files..."
    
    # Ensure organizer script exists
    if [ ! -f "${SCRIPTS_DIR}/file_organizer.sh" ]; then
        log_error "File organizer not found: ${SCRIPTS_DIR}/file_organizer.sh"
        return 1
    fi
    
    # Run file organizer with atomic operations
    if bash "${SCRIPTS_DIR}/file_organizer.sh"; then
        log "✅ File organization completed successfully"
        
        # Verify files were moved correctly
        local organized_files=$(find "$MODELS_DIR" -type f | wc -l)
        log "Total files in models directory: $organized_files"
        
        # Clean up empty downloads directory
        if [ -d "$DOWNLOADS_TMP" ]; then
            find "$DOWNLOADS_TMP" -type d -empty -delete 2>/dev/null || true
            if [ -d "$DOWNLOADS_TMP" ] && [ $(find "$DOWNLOADS_TMP" -type f | wc -l) -eq 0 ]; then
                log "Removing empty downloads directory"
                rm -rf "$DOWNLOADS_TMP"
            fi
        fi
    else
        log_error "File organization failed - files may still be in downloads_tmp"
        log "Check /home/comfyuser/workspace/debug/failed_downloads for preserved files"
        return 1
    fi
    
    return 0
}

# --- Service Startup Phase ---
start_services() {
    log "=== PHASE 4: Service Startup ==="
    
    # Validate ComfyUI environment one more time
    cd "${COMFYUI_DIR}" || {
        log_error "Cannot access ComfyUI directory: ${COMFYUI_DIR}"
        return 1
    }
    
    # Test Python can import ComfyUI modules
    if ! "${PYTHON_EXEC}" -c "
import sys
sys.path.insert(0, '${COMFYUI_DIR}')
try:
    import main
    print('ComfyUI modules importable')
except Exception as e:
    print(f'Import test failed: {e}')
    sys.exit(1)
" >/dev/null 2>&1; then
        log_error "ComfyUI Python environment test failed"
        return 1
    fi
    
    # Parse ComfyUI flags
    local comfyui_flags=\"${COMFYUI_FLAGS:-}\"
    log "Starting ComfyUI server with flags: ${comfyui_flags}"
    
    # Start ComfyUI with proper signal handling
    log "Launching ComfyUI..."
    exec "${PYTHON_EXEC}" main.py --listen 0.0.0.0 --port 8188 ${comfyui_flags}
}

# --- Main Execution ---
main() {
    log "🚀 Initializing Catalyst container startup sequence..."
    
    # Phase 1: File system preparation
    if ! setup_filesystem; then
        log_error "File system setup failed, aborting startup"
        exit 1
    fi
    
    # Phase 2: Security initialization  
    log "=== PHASE 2: Security Initialization ==="
    if [ -f "${SCRIPTS_DIR}/network_security.sh" ]; then
        bash "${SCRIPTS_DIR}/network_security.sh"
    else
        log "Warning: network_security.sh not found, skipping..."
    fi
    
    # Phase 3: Model downloads
    if ! execute_downloads; then
        log_error "Download phase failed, but continuing with startup..."
    fi
    
    # Phase 4: File organization  
    if ! organize_files; then
        log_error "File organization failed, but continuing with startup..."
    fi
    
    # Phase 5: Service startup (this becomes the main process)
    start_services
}

# --- Validation Before Main ---
log "Performing pre-startup validation..."

# Validate critical environment
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

# Run main startup sequence
main
