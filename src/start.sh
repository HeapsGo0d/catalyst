#!/bin/bash
# ==================================================================================
# CATALYST: CONTAINER STARTUP SCRIPT
# ==================================================================================
# This script serves as the container entrypoint. It handles environment
# validation, security script integration, and the startup of the ComfyUI service.
# ----------------------------------------------------------------------------------

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
    # Add any specific cleanup tasks here
    wait "${!}"
    log "ComfyUI has been shut down."
    exit 0
}

# --- Pre-Startup Validation and Setup ---
log "Initializing Catalyst container..."

# Redirect all output to a log file for debugging if needed
# exec &> >(tee -a "/home/comfyuser/workspace/container.log")

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
bash "${SCRIPTS_DIR}/network_security.sh"

# --- File Organization ---
log "Running file organizer..."
bash "${SCRIPTS_DIR}/file_organizer.sh"

# --- ComfyUI Startup ---
cd "${COMFYUI_DIR}"
log "Starting ComfyUI server..."
log "Command: ${PYTHON_EXEC} main.py --listen 0.0.0.0 --port 8188"

# Launch ComfyUI in the background
${PYTHON_EXEC} main.py --listen 0.0.0.0 --port 8188 &
CHILD_PID=$!

# Wait for the process and handle exit codes
wait ${CHILD_PID}
EXIT_CODE=$?

if [ ${EXIT_CODE} -ne 0 ]; then
    log_error "ComfyUI exited with a non-zero status code: ${EXIT_CODE}."
    log_error "Check the logs above for details."
    # Optional: Add a delay to allow log inspection before container exits
    # sleep 60
fi

# --- Post-Shutdown Cleanup ---
log "Running forensic cleanup placeholder script..."
bash "${SCRIPTS_DIR}/forensic_cleanup.sh"

log "Catalyst container has finished execution."
exit ${EXIT_CODE}