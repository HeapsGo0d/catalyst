# syntax=docker/dockerfile:1.7

# Single-stage, slim runtime
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    VIRTUAL_ENV=/opt/venv \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# System deps + Python 3.11 + gosu
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        build-essential gcc ninja-build \
        git curl jq aria2 git-lfs gosu \
        ffmpeg libgl1 libglib2.0-0 wget ca-certificates vim && \
    printf "/usr/local/cuda-12.8/lib64\n/usr/local/cuda-12.8/targets/x86_64-linux/lib\n" > /etc/ld.so.conf.d/cuda.conf && ldconfig && \
    rm -rf /var/lib/apt/lists/*

# Self-contained venv
RUN /usr/bin/python3.11 -m venv --copies /opt/venv && \
    cp -f /usr/bin/python3.11 /opt/venv/bin/python3.11 && \
    ln -sf /opt/venv/bin/python3.11 /opt/venv/bin/python
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV PYTHON="${VIRTUAL_ENV}/bin/python"
ENV PIP="${VIRTUAL_ENV}/bin/pip"
ENV LD_LIBRARY_PATH="/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"

# App user with fixed UID/GID 1000 (reuse existing gid if present)
RUN set -eux; \
    uid=1000; gid=1000; \
    if ! getent group "$gid" >/dev/null; then \
        groupadd -g "$gid" comfyuser; \
    else \
        echo "Using existing group $(getent group $gid | cut -d: -f1) (gid=$gid)"; \
    fi; \
    if id -u comfyuser >/dev/null 2>&1; then \
        usermod -u "$uid" -g "$gid" -s /bin/bash comfyuser; \
    else \
        useradd -m -u "$uid" -g "$gid" -s /bin/bash comfyuser; \
    fi; \
    mkdir -p /home/comfyuser/workspace /workspace /home/comfyuser/.cache/pip && \
    chown -R 1000:1000 /home/comfyuser /workspace /opt/venv
ENV HOME=/home/comfyuser
ENV PIP_CACHE_DIR=/home/comfyuser/.cache/pip

# Version pins and requirements
COPY --chown=1000:1000 config/versions.conf /tmp/versions.conf
COPY --chown=1000:1000 config/requirements.txt /tmp/requirements.txt

# Torch (from versions.conf) + base reqs (hashes stripped)
RUN --mount=type=cache,target=/home/comfyuser/.cache/pip \
    . /tmp/versions.conf && \
    ${PYTHON} -m pip install --upgrade --no-cache-dir pip setuptools wheel && \
    ${PYTHON} -m pip install --no-cache-dir \
        --index-url "${PYTORCH_INDEX_URL}" \
        torch=="${PYTORCH_VERSION}" torchvision=="${TORCHVISION_VERSION}" torchaudio=="${TORCHAUDIO_VERSION}" && \
    sed -E 's/ --hash=sha256:[a-f0-9]+//g' /tmp/requirements.txt > /tmp/requirements.nohash.txt && \
    ${PYTHON} -m pip install --no-cache-dir -r /tmp/requirements.nohash.txt

# Quick Torch import test
RUN ${PYTHON} - <<'PY'
import torch, platform
print("torch", torch.__version__, "cuda", getattr(torch.version, "cuda", "n/a"), "python", platform.python_version())
PY

# ComfyUI clone + setup (pinned repo/branch from versions.conf)
RUN --mount=type=cache,target=/home/comfyuser/.cache/pip \
    . /tmp/versions.conf && \
    git clone --depth 1 --branch "${COMFYUI_VERSION}" "${COMFYUI_REPO}" /home/comfyuser/workspace/ComfyUI && \
    cd /home/comfyuser/workspace/ComfyUI && \
    ${PIP} install --no-cache-dir -r requirements.txt && \
    ${PIP} install --no-cache-dir huggingface-cli && \
    find . -type d | while read -r dir; do \
      if [ -n "$(find "$dir" -maxdepth 1 -name '*.py' -print -quit)" ]; then \
        [ -f "$dir/__init__.py" ] || touch "$dir/__init__.py"; \
      fi; \
    done && \
    for pkg_dir in utils app comfy model_management nodes execution; do \
      [ -d "$pkg_dir" ] && touch "$pkg_dir/__init__.py"; \
    done && \
    ${PIP} install --no-cache-dir xformers --index-url "${XFORMERS_INDEX_URL}" || echo "xformers wheel not available; continuing"

# Ensure ComfyUI user & models dirs exist and are writable
RUN cd /home/comfyuser/workspace/ComfyUI && \
    mkdir -p user/default/workflows user/default/models user/default/settings && \
    mkdir -p models/checkpoints models/loras models/vae models/diffusers models/clip_vision models/controlnet && \
    chown -R 1000:1000 user/ models/

# Scripts and configs
COPY --chown=1000:1000 src/ /home/comfyuser/scripts/
COPY --chown=1000:1000 config/ /home/comfyuser/config/

# Normalize line endings, make scripts executable
RUN set -euo pipefail; \
    shopt -s nullglob; \
    for f in /home/comfyuser/scripts/*.sh; do sed -i 's/\r$//' "$f"; chmod +x "$f"; done; \
    echo "PATH=$PATH"; "$PYTHON" -V; "$PIP" -V

WORKDIR /home/comfyuser/workspace

# IMPORTANT: start as root so start.sh can fix volume ownership, then gosu -> comfyuser
USER root

EXPOSE 8188
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/home/comfyuser/scripts/start.sh"]
