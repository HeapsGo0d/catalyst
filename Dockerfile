# Single-stage build for RunPod reliability
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

# Consolidated environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    PATH="/opt/venv/bin:$PATH"

# System dependencies, Python, and venv setup
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common python3-pip \
        curl ffmpeg ninja-build git aria2 git-lfs wget vim \
        libgl1 libglib2.0-0 build-essential gcc && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev && \
    ln -sf /usr/bin/python3.11 /usr/bin/python && \
    ln -sf /usr/bin/pip3 /usr/bin/pip && \
    python3.11 -m venv /opt/venv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Python dependencies and ComfyUI installation with combined config files
COPY config/ /tmp/config/
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r /tmp/config/requirements.txt && \
    . /tmp/config/versions.conf && pip install torch==${PYTORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url ${PYTORCH_INDEX_URL} && \
    pip install opencv-python && \
    . /tmp/config/versions.conf && \
    git clone "${COMFYUI_REPO}" /ComfyUI && \
    cd /ComfyUI && \
    git checkout "${COMFYUI_VERSION}" && \
    pip install -r requirements.txt && \
    rm -rf /tmp/config

# Install ComfyUI custom nodes with enhanced error handling
RUN --mount=type=cache,target=/root/.cache/pip \
    cd /ComfyUI/custom_nodes && \
    # Initialize error tracking
    echo "=== ComfyUI Custom Nodes Installation Log ===" > /tmp/custom_nodes_install.log && \
    echo "Starting installation at $(date)" >> /tmp/custom_nodes_install.log && \
    FAILED_REPOS="" && \
    SUCCESSFUL_REPOS="" && \
    TOTAL_REPOS=0 && \
    FAILED_COUNT=0 && \
    for repo in \
        https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git \
        https://github.com/kijai/ComfyUI-KJNodes.git \
        https://github.com/rgthree/rgthree-comfy.git \
        https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git \
        https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
        https://github.com/Jordach/comfy-plasma.git \
        https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
        https://github.com/Fannovel16/comfyui_controlnet_aux.git \
        https://github.com/yolain/ComfyUI-Easy-Use.git \
        https://github.com/kijai/ComfyUI-Florence2.git \
        https://github.com/WASasquatch/was-node-suite-comfyui.git \
        https://github.com/theUpsider/ComfyUI-Logic.git \
        https://github.com/cubiq/ComfyUI_essentials.git \
        https://github.com/chrisgoringe/cg-image-picker.git \
        https://github.com/chflame163/ComfyUI_LayerStyle.git \
        https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git \
        https://github.com/Jonseed/ComfyUI-Detail-Daemon.git \
        https://github.com/shadowcz007/comfyui-mixlab-nodes.git \
        https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git \
        https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
        https://github.com/bash-j/mikey_nodes.git \
        https://github.com/1038lab/ComfyUI-JoyCaption.git \
        https://github.com/sipie800/ComfyUI-PuLID-Flux-Enhanced.git \
        https://github.com/chrisgoringe/cg-use-everywhere.git \
        https://github.com/M1kep/ComfyLiterals.git; \
    do \
        TOTAL_REPOS=$((TOTAL_REPOS + 1)); \
        repo_name=$(basename "$repo" .git); \
        echo "Processing repository: $repo_name" >> /tmp/custom_nodes_install.log; \
        \
        # Clone repository with error handling
        echo "  Attempting to clone $repo..." >> /tmp/custom_nodes_install.log; \
        if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then \
            if git clone --recursive "$repo" 2>> /tmp/custom_nodes_install.log; then \
                echo "  ✓ Successfully cloned $repo_name (recursive)" >> /tmp/custom_nodes_install.log; \
            else \
                echo "  ✗ FAILED to clone $repo_name (recursive)" >> /tmp/custom_nodes_install.log; \
                FAILED_REPOS="$FAILED_REPOS $repo_name"; \
                FAILED_COUNT=$((FAILED_COUNT + 1)); \
                continue; \
            fi; \
        else \
            if git clone "$repo" 2>> /tmp/custom_nodes_install.log; then \
                echo "  ✓ Successfully cloned $repo_name" >> /tmp/custom_nodes_install.log; \
            else \
                echo "  ✗ FAILED to clone $repo_name" >> /tmp/custom_nodes_install.log; \
                FAILED_REPOS="$FAILED_REPOS $repo_name"; \
                FAILED_COUNT=$((FAILED_COUNT + 1)); \
                continue; \
            fi; \
        fi; \
        \
        # Remove .git directories to reduce image size
        rm -rf "$repo_name/.git" 2>/dev/null || true; \
        \
        # Install requirements.txt with error handling
        if [ -f "$repo_name/requirements.txt" ]; then \
            echo "  Installing requirements for $repo_name..." >> /tmp/custom_nodes_install.log; \
            if pip install --no-cache-dir -r "$repo_name/requirements.txt" 2>> /tmp/custom_nodes_install.log; then \
                echo "  ✓ Successfully installed requirements for $repo_name" >> /tmp/custom_nodes_install.log; \
            else \
                echo "  ⚠ WARNING: Failed to install requirements for $repo_name (non-critical)" >> /tmp/custom_nodes_install.log; \
            fi; \
        else \
            echo "  No requirements.txt found for $repo_name" >> /tmp/custom_nodes_install.log; \
        fi; \
        \
        # Run install.py script with error handling
        if [ -f "$repo_name/install.py" ]; then \
            echo "  Running install script for $repo_name..." >> /tmp/custom_nodes_install.log; \
            if python "$repo_name/install.py" 2>> /tmp/custom_nodes_install.log; then \
                echo "  ✓ Successfully ran install script for $repo_name" >> /tmp/custom_nodes_install.log; \
            else \
                echo "  ⚠ WARNING: Failed to run install script for $repo_name (non-critical)" >> /tmp/custom_nodes_install.log; \
            fi; \
        else \
            echo "  No install.py found for $repo_name" >> /tmp/custom_nodes_install.log; \
        fi; \
        \
        SUCCESSFUL_REPOS="$SUCCESSFUL_REPOS $repo_name"; \
        echo "  ✓ Completed processing $repo_name" >> /tmp/custom_nodes_install.log; \
    done && \
    \
    # Generate installation summary
    echo "" >> /tmp/custom_nodes_install.log && \
    echo "=== Installation Summary ===" >> /tmp/custom_nodes_install.log && \
    echo "Total repositories processed: $TOTAL_REPOS" >> /tmp/custom_nodes_install.log && \
    echo "Successfully installed: $((TOTAL_REPOS - FAILED_COUNT))" >> /tmp/custom_nodes_install.log && \
    echo "Failed installations: $FAILED_COUNT" >> /tmp/custom_nodes_install.log && \
    \
    if [ $FAILED_COUNT -gt 0 ]; then \
        echo "Failed repositories:$FAILED_REPOS" >> /tmp/custom_nodes_install.log; \
        echo "WARNING: $FAILED_COUNT custom node repositories failed to install" >> /tmp/custom_nodes_install.log; \
    fi && \
    \
    if [ $FAILED_COUNT -lt $TOTAL_REPOS ]; then \
        echo "Successfully installed repositories:$SUCCESSFUL_REPOS" >> /tmp/custom_nodes_install.log; \
    fi && \
    \
    echo "Installation completed at $(date)" >> /tmp/custom_nodes_install.log && \
    \
    # Display summary to build output
    echo "=== Custom Nodes Installation Summary ===" && \
    echo "Total: $TOTAL_REPOS | Success: $((TOTAL_REPOS - FAILED_COUNT)) | Failed: $FAILED_COUNT" && \
    if [ $FAILED_COUNT -gt 0 ]; then \
        echo "Failed repositories:$FAILED_REPOS"; \
        echo "Check /tmp/custom_nodes_install.log for detailed error information"; \
    fi && \
    \
    # Clean up pip cache and temporary files in the same layer
    pip cache purge && \
    find /tmp -type f -name "*.tmp" -delete && \
    find /tmp -type f -name "*.log" ! -name "custom_nodes_install.log" -delete

# Set up the entrypoint and healthcheck
COPY src/start_script.sh /start_script.sh
COPY src/organizer.py /usr/local/bin/organizer.py
RUN chmod +x /start_script.sh && chmod +x /usr/local/bin/organizer.py

WORKDIR /ComfyUI
ENTRYPOINT ["/start_script.sh"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
  CMD curl -f http://localhost:8188/ || exit 1