# ──────────────────────────────────────────
# Build stage (non-root for pip/git work)
# ──────────────────────────────────────────
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04 AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# System deps + Python 3.11
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        build-essential gcc ninja-build \
        git curl jq aria2 git-lfs \
        ffmpeg libgl1 libglib2.0-0 wget vim && \
    printf "/usr/local/cuda-12.8/lib64\n/usr/local/cuda-12.8/targets/x86_64-linux/lib\n" \
        > /etc/ld.so.conf.d/cuda.conf && ldconfig && \
    rm -rf /var/lib/apt/lists/*

# Create venv (root), then switch to non-root for installs
RUN /usr/bin/python3.11 -m venv --copies /opt/venv && \
    cp -f /usr/bin/python3.11 /opt/venv/bin/python3.11 && \
    ln -sf /opt/venv/bin/python3.11 /opt/venv/bin/python

# Non-root environment
RUN mkdir -p /workspace /home/ubuntu/.cache/pip && \
    chown -R ubuntu:ubuntu /opt/venv /workspace /home/ubuntu

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV PYTHON="${VIRTUAL_ENV}/bin/python"
ENV PIP="${VIRTUAL_ENV}/bin/pip"
ENV PIP_CACHE_DIR=/home/ubuntu/.cache/pip

USER ubuntu
WORKDIR /workspace
ENV HOME=/home/ubuntu

# Build-time config (PyTorch, ComfyUI versions/URLs)
COPY --chown=ubuntu:ubuntu config/versions.conf /tmp/versions.conf

# PyTorch (CUDA 12.8 wheels)
RUN --mount=type=cache,target=/home/ubuntu/.cache/pip \
    . /tmp/versions.conf && \
    ${PYTHON} -m pip install --upgrade --no-cache-dir pip setuptools wheel && \
    ${PYTHON} -m pip install --no-cache-dir \
        --index-url "${PYTORCH_INDEX_URL}" \
        torch=="${PYTORCH_VERSION}" torchvision=="${TORCHVISION_VERSION}" torchaudio=="${TORCHAUDIO_VERSION}"

# Quick import test
RUN ${PYTHON} - <<'PY'
import torch, platform
print("torch", torch.__version__, "cuda", getattr(torch.version, "cuda", "n/a"), "python", platform.python_version())
PY

# Base requirements (hash-stripped)
COPY --chown=ubuntu:ubuntu config/requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/home/ubuntu/.cache/pip \
    sed -E 's/ --hash=sha256:[a-f0-9]+//g' /tmp/requirements.txt > /tmp/requirements.nohash.txt && \
    ${PYTHON} -m pip install --no-cache-dir -r /tmp/requirements.nohash.txt

# ComfyUI clone + setup (build stage only)
RUN . /tmp/versions.conf && \
    git clone --depth 1 --branch "${COMFYUI_VERSION}" "${COMFYUI_REPO}" /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    ${PIP} install --no-cache-dir -r requirements.txt && \
    ${PIP} install --no-cache-dir huggingface-cli && \
    # Ensure importable packages for dirs with .py files
    find . -type d | while read -r dir; do \
        if [ -n "$(find "$dir" -maxdepth 1 -name "*.py" -print -quit)" ]; then \
            [ -f "$dir/__init__.py" ] || touch "$dir/__init__.py"; \
        fi; \
    done && \
    for pkg_dir in utils app comfy model_management nodes execution; do \
        [ -d "$pkg_dir" ] && touch "$pkg_dir/__init__.py"; \
    done && \
    ${PIP} install --no-cache-dir xformers --index-url "${XFORMERS_INDEX_URL}" || \
    echo "xformers wheel not available; continuing" && \
    rm -rf .git

# Clean caches in build layer
RUN ${PYTHON} -m pip cache purge || true && \
    rm -rf /home/ubuntu/.cache/pip/* /tmp/*


# ──────────────────────────────────────────
# Production stage
# ──────────────────────────────────────────
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04 AS production
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Security/behavior flags (optional)
ENV PARANOID_MODE=false \
    SECURITY_LEVEL=normal \
    NETWORK_MODE=public \
    ENABLE_FORENSIC_CLEANUP=false

# Copy venv and stdlib built against 3.11
COPY --from=build /opt/venv /opt/venv
COPY --from=build /usr/lib/python3.11 /usr/lib/python3.11

# Runtime env
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV PYTHON="${VIRTUAL_ENV}/bin/python"
ENV PIP="${VIRTUAL_ENV}/bin/pip"
ENV LD_LIBRARY_PATH="/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1

# Runtime deps
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl jq aria2 git-lfs \
        ffmpeg libgl1 libglib2.0-0 && \
    printf "/usr/local/cuda-12.8/lib64\n/usr/local/cuda-12.8/targets/x86_64-linux/lib\n" > /etc/ld.so.conf.d/cuda.conf && ldconfig || (echo "CUDA library configuration failed" && exit 1) && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# App user + workspace
RUN useradd -m comfyuser && \
    mkdir -p /home/comfyuser/workspace /workspace && \
    chown -R comfyuser:comfyuser /home/comfyuser /workspace /opt/venv

# ComfyUI from build stage
COPY --from=build --chown=comfyuser:comfyuser /workspace/ComfyUI /home/comfyuser/workspace/ComfyUI

# Scripts and configs
COPY --chown=comfyuser:comfyuser src/ /home/comfyuser/scripts/
COPY --chown=comfyuser:comfyuser config/ /home/comfyuser/config/

# Runtime HOME + pip cache for comfyuser
ENV HOME=/home/comfyuser
RUN mkdir -p /home/comfyuser/.cache/pip && chown -R comfyuser:comfyuser /home/comfyuser/.cache
ENV PIP_CACHE_DIR=/home/comfyuser/.cache/pip

# Fix line endings, make scripts executable, sanity-check venv
RUN set -euo pipefail; \
    shopt -s nullglob; \
    files=(/home/comfyuser/scripts/*.sh); \
    for f in "${files[@]}"; do sed -i 's/\r$//' "$f"; chmod +x "$f"; done; \
    echo "PATH=$PATH"; "$PYTHON" -V; "$PIP" -V

WORKDIR /home/comfyuser/workspace
USER comfyuser

# For recommended security options (e.g., --security-opt=no-new-privileges --cap-drop=ALL), see DOCKER_SECURITY.md

EXPOSE 8188
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/home/comfyuser/scripts/start.sh"]
