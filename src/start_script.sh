#!/bin/bash
set -e

# --- Configuration ---
REPO_URL="https://github.com/HeapsGo0d/catalyst"
INSTALL_DIR="${CATALYST_INSTALL_DIR:-/opt/catalyst}"
LOG_PREFIX="[Catalyst-Updater]"

log() {
    echo "$LOG_PREFIX $1"
}

error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
    exit 1
}

# --- Main Execution ---
log "Starting self-updating script..."

# Check if we have write permissions for installation directory
if [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
    error "No write permissions for $(dirname "$INSTALL_DIR"). Please run with sudo or choose a different directory."
fi

# Check if the directory exists and is a git repository
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Existing installation found. Pulling latest changes..."
    cd "$INSTALL_DIR"
    git pull || error "Failed to pull updates"
else
    log "No existing installation found. Initializing repository..."

    # Create installation directory if it doesn't exist
    mkdir -p "$INSTALL_DIR" || error "Failed to create directory $INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Initialize Git repository
    git init || error "Failed to initialize Git repository"
    git remote add origin "$REPO_URL" || error "Failed to add remote origin"
    git fetch origin || error "Failed to fetch from origin"
    
    # Check if repository exists on GitHub
    if git ls-remote --exit-code origin &> /dev/null; then
        log "Repository exists on GitHub. Pulling code..."
        git pull origin main || error "Failed to pull from origin/main"
    else
        log "Initializing new repository and pushing code..."
        # Add all files and create initial commit
        cp -r /home/nathan/dev/catalyst/* . || error "Failed to copy files"
        git add . || error "Failed to add files to Git"
        git commit -m "Initial commit" || error "Failed to create initial commit"
        git branch -M main || error "Failed to rename branch"
        git push -u origin main || error "Failed to push to origin"
    fi
fi

log "Repository is up to date. Executing main start script..."

# Ensure the start script is executable
chmod +x src/start.sh || error "Failed to make start.sh executable"

# Execute the main start script
exec src/start.sh