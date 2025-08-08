#!/bin/bash
# ==================================================================================
# CATALYST: FORENSIC CLEANUP SCRIPT
# ==================================================================================
# This script performs forensic cleanup operations when enabled.
# All cleanup features are DISABLED by default and must be explicitly enabled.

# --- Logging Function ---
log_cleanup() {
    echo "  [CLEANUP] $1"
}

# --- Error Handling Function ---
log_error() {
    echo "  [ERROR] $1" >&2
}

# --- Path Validation Function ---
validate_path() {
    local path="$1"
    
    # Check if path is empty
    if [ -z "$path" ]; then
        log_error "Path is empty"
        return 1
    fi
    
    # Check for absolute path
    if [[ "$path" != /* ]]; then
        log_error "Path must be absolute: $path"
        return 1
    fi
    
    # Check for critical system paths
    local critical_paths=("/" "/bin" "/sbin" "/usr" "/etc" "/lib" "/lib64" "/boot")
    for critical in "${critical_paths[@]}"; do
        if [[ "$path" == "$critical" || "$path" == "$critical/"* ]]; then
            log_error "Attempt to delete critical system path: $path"
            return 1
        fi
    done
    
    return 0
}

# --- Safe Delete Function ---
safe_delete() {
    local path="$1"
    local paranoid="${2:-false}"
    
    # Validate path before any operations
    if ! validate_path "$path"; then
        return 1
    fi
    
    # Handle file deletion
    if [ -f "$path" ]; then
        if [ "$paranoid" = "true" ]; then
            if ! command -v shred >/dev/null 2>&1; then
                log_error "shred command not available for secure deletion"
                return 1
            fi
            log_cleanup "Securely shredding file: $path"
            if ! shred -n 1 -u -- "$path" 2>/dev/null; then
                log_error "Failed to shred file: $path"
                return 1
            fi
        else
            log_cleanup "Deleting file: $path"
            if ! rm -f -- "$path" 2>/dev/null; then
                log_error "Failed to delete file: $path"
                return 1
            fi
        fi
        return 0
    fi
    
    # Handle directory deletion
    if [ -d "$path" ]; then
        log_cleanup "Deleting directory: $path"
        if ! rm -rf -- "$path" 2>/dev/null; then
            log_error "Failed to delete directory: $path"
            return 1
        fi
        return 0
    fi
    
    # Handle wildcard patterns
    if [[ "$path" == *"*"* ]]; then
        log_cleanup "Processing pattern: $path"
        local deleted_count=0
        local error_count=0
        
        # Expand pattern and process each item
        for item in $path; do
            if [ -e "$item" ]; then
                if ! safe_delete "$item" "$paranoid"; then
                    ((error_count++))
                else
                    ((deleted_count++))
                fi
            fi
        done
        
        if [ $error_count -gt 0 ]; then
            log_error "Failed to delete $error_count items matching pattern: $path"
            return 1
        fi
        
        if [ $deleted_count -eq 0 ]; then
            log_cleanup "No items found matching pattern: $path"
        fi
        return 0
    fi
    
    log_cleanup "Path does not exist: $path"
    return 0
}

log_cleanup "Starting forensic cleanup process..."

# --- Feature Enablement Check ---
if [ "${ENABLE_FORENSIC_CLEANUP:-false}" != "true" ]; then
    log_cleanup "Forensic cleanup is disabled. No files will be removed."
    log_cleanup "To enable, set ENABLE_FORENSIC_CLEANUP=true."
    log_cleanup "✅ Forensic cleanup script finished."
    exit 0
fi

# --- Paranoid Mode Check ---
PARANOID_DELETION="${PARANOID_MODE:-false}"

# --- Target Directories and Files for Deletion ---
declare -a paths_to_delete=(
    # All temporary files in /tmp
    "/tmp/*"
    # Workspace files (input/output)
    "/workspace/input"
    "/workspace/output"
    # Caches
    "/root/.cache/pip"
    "/workspace/.cache"
    "/root/.cache/huggingface"
    # Logs and history
    "/var/log/*.log"
    "/root/.bash_history"
)

# --- Deletion Loop ---
log_cleanup "Starting cleanup operations..."
error_occurred=0

for path in "${paths_to_delete[@]}"; do
    if ! safe_delete "$path" "$PARANOID_DELETION"; then
        error_occurred=1
    fi
done

# --- Python Bytecode Cleanup ---
log_cleanup "Removing Python bytecode cache..."
pycache_dirs=(
    "/home/comfyuser/workspace/ComfyUI"
)

for dir in "${pycache_dirs[@]}"; do
    if [ -d "$dir" ]; then
        log_cleanup "Cleaning __pycache__ in: $dir"
        find "$dir" -type f -name "*.pyc" -delete 2>/dev/null || log_error "Failed to delete .pyc files in $dir"
        find "$dir" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || log_error "Failed to delete __pycache__ in $dir"
    else
        log_cleanup "Skipping non-existent directory: $dir"
    fi
done

# --- Final Status ---
if [ $error_occurred -eq 0 ]; then
    log_cleanup "✅ Forensic cleanup completed successfully."
    exit 0
else
    log_cleanup "⚠️ Forensic cleanup completed with errors. Check logs for details."
    exit 1
fi