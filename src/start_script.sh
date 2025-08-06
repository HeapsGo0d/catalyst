#!/bin/bash
set -e

# --- Configuration ---
REPO_URL="https://github.com/your-username/catalyst.git" # <-- IMPORTANT: Update this to your repository URL
INSTALL_DIR="/opt/catalyst"
LOG_PREFIX="[Catalyst-Updater]"

log() {
    echo "$LOG_PREFIX $1"
}

# --- Main Execution ---
log "Starting self-updating script..."

# Check if the directory exists and is a git repository
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Existing installation found. Pulling latest changes..."
    cd "$INSTALL_DIR"
    git pull
else
    log "No existing installation found. Cloning repository..."
    # Clean up any potential old, non-git directory
    rm -rf "$INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

log "Repository is up to date. Executing main start script..."

# Ensure the start script is executable
chmod +x src/start.sh

# Execute the main start script
exec src/start.sh