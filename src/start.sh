#!/bin/bash
# ==================================================================================
# CATALYST: CONTAINER STARTUP SCRIPT
# ==================================================================================

set -Eeuo pipefail

# --- Environment Variables and Paths ---
LOG_PREFIX="[STARTUP]"
COMFYUI_DIR="/home/comfyuser/workspace/ComfyUI"
PYTHON_EXEC="/opt/venv/bin/python"
SCRIPTS_DIR="/home/comfyuser/scripts"
STARTUP_ERROR_LOG="/home/comfyuser/workspace/startup_errors.log"

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
    log "SIGTERM received. Shutting down ComfyUI gracefully..."
    wait "${!}"
    log "ComfyUI has been shut down."
    exit 0
}

# --- Pre-Startup Validation and Setup ---
log "Initializing Catalyst container..."

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

log "Environment validation passed."

# --- Security Script Integration ---
log "Running network security placeholder script..."
if [ -f "${SCRIPTS_DIR}/network_security.sh" ]; then
    bash "${SCRIPTS_DIR}/network_security.sh"
else
    log "Warning: network_security.sh not found, skipping..."
fi

# --- Model Downloads (Nexis Download Manager) ---
log "Starting model download process..."
if [ -f "${SCRIPTS_DIR}/nexis_downloader.py" ]; then
    # Run the Python download manager
    "${PYTHON_EXEC}" "${SCRIPTS_DIR}/nexis_downloader.py"
    DOWNLOAD_EXIT_CODE=$?
    
    if [ $DOWNLOAD_EXIT_CODE -eq 0 ]; then
        log "Downloads completed successfully."
    else
        log "Downloads completed with some failures (exit code: $DOWNLOAD_EXIT_CODE)."
        log "Continuing with container startup..."
    fi
else
    log "Warning: nexis_downloader.py not found, skipping downloads..."
fi

# --- File Organization ---
log "Running file organizer..."
if [ -f "${SCRIPTS_DIR}/file_organizer.sh" ]; then
    bash "${SCRIPTS_DIR}/file_organizer.sh"
else
    log "Warning: file_organizer.sh not found, skipping..."
fi

# --- ComfyUI Startup ---
cd "${COMFYUI_DIR}"

# Parse ComfyUI flags from environment
COMFYUI_FLAGS="${COMFYUI_FLAGS:-}"
log "Starting ComfyUI server with flags: ${COMFYUI_FLAGS}"
log "Command: ${PYTHON_EXEC} main.py --listen 0.0.0.0 --port 8188 ${COMFYUI_FLAGS}"

# Launch ComfyUI in the background
${PYTHON_EXEC} main.py --listen 0.0.0.0 --port 8188 ${COMFYUI_FLAGS} &
CHILD_PID=$!

# Wait for the process and handle exit codes
wait ${CHILD_PID}
EXIT_CODE=$?

if [ ${EXIT_CODE} -ne 0 ]; then
    log_error "ComfyUI exited with a non-zero status code: ${EXIT_CODE}."
    log_error "Check the logs above for details."
fi

# --- Post-Shutdown Cleanup ---
log "Running forensic cleanup placeholder script..."
if [ -f "${SCRIPTS_DIR}/forensic_cleanup.sh" ]; then
    bash "${SCRIPTS_DIR}/forensic_cleanup.sh"
else
    log "Warning: forensic_cleanup.sh not found, skipping..."
fi

log "Catalyst container has finished execution."
exit ${EXIT_CODE}