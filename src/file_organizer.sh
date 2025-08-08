#!/bin/bash

echo "[ORGANIZER] Starting file organization..."

# Create debug directory for failed downloads
mkdir -p /home/comfyuser/workspace/debug/failed_downloads

# Source directory where downloads are stored
DOWNLOADS_TMP="/home/comfyuser/workspace/downloads_tmp"

# Check if downloads directory exists
if [ ! -d "$DOWNLOADS_TMP" ]; then
    echo "[ORGANIZER] No downloads directory found at $DOWNLOADS_TMP. Nothing to organize."
    exit 0
fi

# Function to move files with error handling
move_files() {
    local source_dir="$1"
    local dest_dir="$2"
    local category="$3"
    
    if [ ! -d "$source_dir" ]; then
        echo "[ORGANIZER] Skipping $category: directory $source_dir does not exist"
        return 0
    fi
    
    # Check if directory is empty
    if [ -z "$(find "$source_dir" -type f -print -quit)" ]; then
        echo "[ORGANIZER] Skipping $category: no files found in $source_dir"
        return 0
    fi
    
    echo "[ORGANIZER] Processing $category files from $source_dir..."
    
    # Create destination directory
    mkdir -p "$dest_dir"
    
    local file_count=0
    local success_count=0
    local failed_count=0
    
    # Process all files in the source directory
    while read -r file; do
        file_count=$((file_count + 1))
        filename=$(basename "$file")
        
        if [ "$DEBUG_MODE" = "true" ]; then
            file_size=$(du -h "$file" | cut -f1)
            echo "[ORGANIZER] Moving $filename ($file_size) to $dest_dir"
        fi
        
        # Try to move the file
        if mv "$file" "$dest_dir/" 2>/dev/null; then
            success_count=$((success_count + 1))
            echo "[ORGANIZER] Successfully moved $filename"
        else
            failed_count=$((failed_count + 1))
            echo "[ORGANIZER] Failed to move $filename, preserving in debug folder"
            
            # Create debug subdirectory structure
            debug_subdir="/home/comfyuser/workspace/debug/failed_downloads/$category"
            mkdir -p "$debug_subdir"
            
            # Move to debug folder instead
            if ! mv "$file" "$debug_subdir/" 2>/dev/null; then
                echo "[ORGANIZER] ERROR: Could not preserve $filename in debug folder"
            fi
        fi
    done < <(find "$source_dir" -type f)
    
    echo "[ORGANIZER] $category: $success_count moved successfully, $failed_count preserved in debug"
}

# Function to preserve directory structure for HuggingFace models
move_huggingface_files() {
    local source_dir="$DOWNLOADS_TMP/huggingface"
    local dest_base="/home/comfyuser/workspace/models"
    
    if [ ! -d "$source_dir" ]; then
        echo "[ORGANIZER] Skipping HuggingFace models: directory $source_dir does not exist"
        return 0
    fi
    
    # Check if directory is empty (no subdirectories)
    if [ -z "$(find "$source_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
        echo "[ORGANIZER] Skipping HuggingFace models: no model directories found in $source_dir"
        return 0
    fi
    
    echo "[ORGANIZER] Processing HuggingFace models with directory structure preservation..."
    
    # Find all subdirectories in huggingface folder
    while read -r model_dir; do
        model_name=$(basename "$model_dir")
        dest_dir="$dest_base/$model_name"
        
        echo "[ORGANIZER] Moving HuggingFace model: $model_name"
        
        if [ "$DEBUG_MODE" = "true" ]; then
            dir_size=$(du -sh "$model_dir" | cut -f1)
            echo "[ORGANIZER] Model $model_name size: $dir_size"
        fi
        
        # Try to move the entire model directory
        if mv "$model_dir" "$dest_dir" 2>/dev/null; then
            echo "[ORGANIZER] Successfully moved HuggingFace model: $model_name"
        else
            echo "[ORGANIZER] Failed to move $model_name, preserving in debug folder"
            
            # Create debug subdirectory
            debug_subdir="/home/comfyuser/workspace/debug/failed_downloads/huggingface"
            mkdir -p "$debug_subdir"
            
            # Move to debug folder
            if ! mv "$model_dir" "$debug_subdir/" 2>/dev/null; then
                echo "[ORGANIZER] ERROR: Could not preserve $model_name in debug folder"
            fi
        fi
    done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -type d)
}

# Organize files by category
move_files "$DOWNLOADS_TMP/checkpoints" "/home/comfyuser/workspace/models/checkpoints" "checkpoints"
move_files "$DOWNLOADS_TMP/loras" "/home/comfyuser/workspace/models/loras" "loras"
move_files "$DOWNLOADS_TMP/vae" "/home/comfyuser/workspace/models/vae" "vae"

# Handle HuggingFace models with directory structure preservation
move_huggingface_files

# Clean up empty directories in downloads_tmp
echo "[ORGANIZER] Cleaning up empty directories..."
find "$DOWNLOADS_TMP" -type d -empty -delete 2>/dev/null || true

# Show summary
if [ "$DEBUG_MODE" = "true" ]; then
    echo "[ORGANIZER] Organization summary:"
    echo "[ORGANIZER] - Checkpoints: $(find /home/comfyuser/workspace/models/checkpoints -type f 2>/dev/null | wc -l) files"
    echo "[ORGANIZER] - LoRAs: $(find /home/comfyuser/workspace/models/loras -type f 2>/dev/null | wc -l) files"
    echo "[ORGANIZER] - VAEs: $(find /home/comfyuser/workspace/models/vae -type f 2>/dev/null | wc -l) files"
    echo "[ORGANIZER] - HuggingFace models: $(find /home/comfyuser/workspace/models -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) directories"
    echo "[ORGANIZER] - Failed downloads in debug: $(find /home/comfyuser/workspace/debug/failed_downloads -type f 2>/dev/null | wc -l) files"
fi

echo "[ORGANIZER] File organization completed."
exit 0