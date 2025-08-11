# ──────────────────────────────────────────
# Single-stage, slim runtime image (keeps your requirements.txt, versions.conf, and scripts)
# ──────────────────────────────────────────
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    VIRTUAL_ENV=/opt/venv

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
        ffmpeg libgl1 libglib2.0-0 wget ca-certificates vim && \
    printf "/usr/local/cuda-12.8/lib64\n/usr/local/cuda-12.8/targets/x86_64-linux/lib\n" > /etc/ld.so.conf.d/cuda.conf && ldconfig && \
    rm -rf /var/lib/apt/lists/*

# Create venv once (runtime stage only)
RUN /usr/bin/python3.11 -m venv --copies /opt/venv && \
    cp -f /usr/bin/python3.11 /opt/venv/bin/python3.11 && \
    ln -sf /opt/venv/bin/python3.11 /opt/venv/bin/python
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV PYTHON="${VIRTUAL_ENV}/bin/python"
ENV PIP="${VIRTUAL_ENV}/bin/pip"
ENV LD_LIBRARY_PATH="/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1

# App user + workspace
RUN useradd -m comfyuser && \
    mkdir -p /home/comfyuser/workspace /workspace && \
    chown -R comfyuser:comfyuser /home/comfyuser /workspace /opt/venv
ENV HOME=/home/comfyuser
ENV PIP_CACHE_DIR=/home/comfyuser/.cache/pip
RUN mkdir -p "${PIP_CACHE_DIR}" && chown -R comfyuser:comfyuser "${PIP_CACHE_DIR}"

# Bring in your version pins and base requirements
COPY --chown=comfyuser:comfyuser config/versions.conf /tmp/versions.conf
COPY --chown=comfyuser:comfyuser config/requirements.txt /tmp/requirements.txt

# Install Torch (from your versions.conf) + base requirements (hashes stripped)
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

# ComfyUI clone + setup (using your pinned repo/branch in versions.conf)
RUN --mount=type=cache,target=/home/comfyuser/.cache/pip \
    . /tmp/versions.conf && \
    git clone --depth 1 --branch "${COMFYUI_VERSION}" "${COMFYUI_REPO}" /home/comfyuser/workspace/ComfyUI && \
    cd /home/comfyuser/workspace/ComfyUI && \
    ${PIP} install --no-cache-dir -r requirements.txt && \
    ${PIP} install --no-cache-dir huggingface-cli && \
    # Ensure importable packages for dirs with .py files
    find . -type d | while read -r dir; do \
      if [ -n "$(find "$dir" -maxdepth 1 -name '*.py' -print -quit)" ]; then \
        [ -f "$dir/__init__.py" ] || touch "$dir/__init__.py"; \
      fi; \
    done && \
    for pkg_dir in utils app comfy model_management nodes execution; do \
      [ -d "$pkg_dir" ] && touch "$pkg_dir/__init__.py"; \
    done && \
    ${PIP} install --no-cache-dir xformers --index-url "${XFORMERS_INDEX_URL}" || echo "xformers wheel not available; continuing"

# Copy ALL your scripts/configs (start.sh, file_organizer.sh, download_manager.sh, nexis_downloader.py, etc.)
COPY --chown=comfyuser:comfyuser src/ /home/comfyuser/scripts/
COPY --chown=comfyuser:comfyuser config/ /home/comfyuser/config/

# Fix line endings, make scripts executable, show versions
RUN set -euo pipefail; \
    shopt -s nullglob; \
    files=(/home/comfyuser/scripts/*.sh); \
    for f in "${files[@]}"; do sed -i 's/\r$//' "$f"; chmod +x "$f"; done; \
    echo "PATH=$PATH"; "$PYTHON" -V; "$PIP" -V

# (Optional) Trim a little
# RUN find /opt/venv -type f -name "*.a" -delete && \
#     find /opt/venv -type f -name "*.pyc" -delete && \
#     find /opt/venv -type f -name "*.pyo" -delete

WORKDIR /home/comfyuser/workspace
USER comfyuser

EXPOSE 8188
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/home/comfyuser/scripts/start.sh"]
