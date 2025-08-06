#!/bin/bash
set -e

# --- Configuration ---
COMFYUI_DIR="/opt/ComfyUI"
MODELS_DIR="$COMFYUI_DIR/models"
LOG_PREFIX="[Catalyst]"

# --- Helper Functions ---
log() {
    echo "$LOG_PREFIX $1"
}

download_file() {
    local url="$1"
    local dest_dir="$2"
    local filename="$3"

    if [ -z "$filename" ]; then
        # Attempt to get filename from URL
        filename=$(basename "$url" | sed 's/\?.*//')
    fi

    local dest_path="$dest_dir/$filename"

    if [ -f "$dest_path" ]; then
        log "File already exists: $filename. Skipping download."
        return
    fi

    log "Downloading '$filename' to '$dest_dir'..."
    mkdir -p "$dest_dir"
    aria2c --console-log-level=error -c -x 16 -s 16 -k 1M -d "$dest_dir" -o "$filename" "$url"
    log "Download complete: $filename"
}

# --- Model Downloaders ---
download_civitai_models() {
    if [ -z "$CIVITAI_MODEL_IDS" ]; then
        log "No CivitAI model IDs provided (CIVITAI_MODEL_IDS is empty). Skipping."
        return
    fi

    log "Processing CivitAI Model IDs: $CIVITAI_MODEL_IDS"
    IFS=',' read -ra C_IDS <<< "$CIVITAI_MODEL_IDS"
    for model_id in "${C_IDS[@]}"; do
        log "Fetching metadata for CivitAI model ID: $model_id"
        local api_url="https://civitai.com/api/v1/models/$model_id"
        
        local response
        response=$(curl -s "$api_url")
        
        if echo "$response" | jq -e '.error' > /dev/null; then
            log "ERROR: Failed to fetch metadata for model ID $model_id. Response: $(echo "$response" | jq -r '.error')"
            continue
        fi

        local model_type
        model_type=$(echo "$response" | jq -r '.type')
        
        local model_version_id
        model_version_id=$(echo "$response" | jq -r '.modelVersions.id')
        
        local version_api_url="https://civitai.com/api/v1/model-versions/$model_version_id"
        local version_response
        version_response=$(curl -s "$version_api_url")

        local download_url
        download_url=$(echo "$version_response" | jq -r '.files.downloadUrl')
        local filename
        filename=$(echo "$version_response" | jq -r '.files.name')

        local dest_dir
        case "$model_type" in
            "LORA") dest_dir="$MODELS_DIR/loras" ;;
            "Checkpoint") dest_dir="$MODELS_DIR/checkpoints" ;;
            "TextualInversion") dest_dir="$MODELS_DIR/embeddings" ;;
            "VAE") dest_dir="$MODELS_DIR/vae" ;;
            "Controlnet") dest_dir="$MODELS_DIR/controlnet" ;;
            "Upscaler") dest_dir="$MODELS_DIR/upscale_models" ;;
            *)
                log "Warning: Unknown model type '$model_type' for ID $model_id. Downloading to '$MODELS_DIR/other'."
                dest_dir="$MODELS_DIR/other"
                ;;
        esac

        download_file "$download_url" "$dest_dir" "$filename"
    done
}

# --- Service Management ---
start_services() {
    log "Starting services..."

    # 1. Start FileBrowser (in background)
    if [[ "${ENABLE_FILEBROWSER}" == "true" ]]; then
        log "Starting FileBrowser..."
        filebrowser -r / --no-auth &
        log "FileBrowser started."
    else
        log "FileBrowser is disabled."
    fi

    # 2. Start ComfyUI (in foreground)
    log "Changing to ComfyUI directory: $COMFYUI_DIR"
    cd "$COMFYUI_DIR"
    
    local comfy_args="--listen --port 8188"
    if [[ "${PREVIEW_METHOD}" == "auto" ]]; then
        comfy_args="$comfy_args --auto-launch"
    fi
    if [[ "${ENABLE_CUDA_MALLOC}" == "true" ]]; then
        comfy_args="$comfy_args --cuda-malloc"
    fi
    
    log "Starting ComfyUI with args: $comfy_args"
    exec python main.py $comfy_args
}

# --- Main Execution ---
main() {
    log "Catalyst startup sequence initiated."
    
    # Run downloaders
    download_civitai_models
    
    # Start main services
    start_services

    log "Catalyst startup sequence complete."
}

main