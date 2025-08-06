# --- Base Image ---
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

# --- Environment Variables ---
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
ENV PYTHON_VERSION=3.11
ENV VENV_DIR=/opt/venv
ENV COMFYUI_DIR=/opt/ComfyUI
ENV PATH="$VENV_DIR/bin:$PATH"

# --- System Dependencies ---
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    aria2 \
    jq \
    curl \
    wget \
    unzip \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    libgl1 \
    libglib2.0-0 && \
    rm -rf /var/lib/apt/lists/*

# --- Python Virtual Environment ---
RUN python${PYTHON_VERSION} -m venv $VENV_DIR
ENV PATH="$VENV_DIR/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip wheel

# --- PyTorch Installation ---
RUN pip install --no-cache-dir --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu121

# --- ComfyUI Installation ---
RUN pip install --no-cache-dir comfy-cli && \
    comfy-cli --install-comfyui --path $COMFYUI_DIR

WORKDIR $COMFYUI_DIR

# --- Custom Nodes Installation ---
# This list is based on the proven Hearmeman/comfyui-flux-template
RUN comfy-cli --install-custom-node https://github.com/ltdrdata/ComfyUI-Manager.git && \
    comfy-cli --install-custom-node https://github.com/comfyanonymous/ComfyUI_Custom_Nodes_AlekPet.git && \
    comfy-cli --install-custom-node https://github.com/Derfuu/Derfuu_ComfyUI_ModdedNodes.git && \
    comfy-cli --install-custom-node https://github.com/jags111/efficiency-nodes-comfyui.git && \
    comfy-cli --install-custom-node https://github.com/WASasquatch/was-node-suite-comfyui.git && \
    comfy-cli --install-custom-node https://github.com/FizzleDorf/ComfyUI_FizzNodes.git && \
    comfy-cli --install-custom-node https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git && \
    comfy-cli --install-custom-node https://github.com/crystian/ComfyUI-Crystools.git && \
    comfy-cli --install-custom-node https://github.com/cubiq/ComfyUI_essentials.git && \
    comfy-cli --install-custom-node https://github.com/Fannovel16/comfyui_controlnet_aux.git && \
    comfy-cli --install-custom-node https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git && \
    comfy-cli --install-custom-node https://github.com/jthri/ComfyUI-FLUX.git && \
    comfy-cli --install-custom-node https://github.com/melMass/comfy_mtb.git && \
    comfy-cli --install-custom-node https://github.com/shiimizu/ComfyUI-PhotoMaker.git && \
    comfy-cli --install-custom-node https://github.com/ZHO-ZHO-ZHO/ComfyUI-InstantID.git && \
    comfy-cli --install-custom-node https://github.com/Gourieff/comfyui-reactor-node.git && \
    pip install --no-cache-dir insightface==0.7.3 && \
    pip install --no-cache-dir onnxruntime-gpu

# --- Application Dependencies & Scripts ---
COPY config/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY src /opt/catalyst/src
RUN chmod +x /opt/catalyst/src/*.sh

# --- Ports and Entrypoint ---
EXPOSE 8188
WORKDIR /
ENTRYPOINT [ "/opt/catalyst/src/start_script.sh" ]

# --- Healthcheck ---
HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD curl --fail http://localhost:8188/ || exit 1