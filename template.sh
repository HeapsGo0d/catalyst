#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# CATALYST: RUNPOD TEMPLATE DEPLOYMENT SCRIPT
# ==================================================================================
# This script creates or updates the RunPod template for Project Catalyst.

# ─── Configuration ──────────────────────────────────────────────────────────
# ⚠️ IMPORTANT: Update this to your Docker Hub username and image name.
readonly IMAGE_NAME="heapsgo0d/catalyst:v1.0.0"
readonly TEMPLATE_NAME="ComfyUI FLUX - Project Catalyst"
readonly CUSTOM_DNS_SERVERS="${CUSTOM_DNS_SERVERS:-"8.8.8.8,1.1.1.1"}" # Default to Google and Cloudflare

# ─── Docker Arguments Construction ─────────────────────────────────
# Build the docker arguments string with required capabilities for GPU/network
docker_args="--security-opt=no-new-privileges"
docker_args+=" --cap-drop=ALL"
docker_args+=" --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE"  # Required for file operations
docker_args+=" --cap-add=NET_BIND_SERVICE"  # Required for binding ports
IFS=',' read -ra dns_servers <<< "$CUSTOM_DNS_SERVERS"
for server in "${dns_servers[@]}"; do
  docker_args+=" --dns=$server"
done
# Add an in-memory tmpfs for secrets (keeps secrets off disk)
docker_args+=" --tmpfs /run/secrets:rw,noexec,nosuid,nodev,size=1m"

# ─── Pre-flight Checks ──────────────────────────────────────────────────────
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  echo "❌ Error: RUNPOD_API_KEY environment variable is not set." >&2
  echo "   Please set it with: export RUNPOD_API_KEY='your_api_key'" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "❌ Error: This script requires 'jq' and 'curl'. Please install them." >&2
  exit 1
fi
echo "✅ Pre-flight checks passed."

# ─── README Content Definition ──────────────────────────────────────────────
# This README is generated from Catalyst's security-focused requirements.
README_CONTENT=$(cat <<'EOF'
# ComfyUI FLUX - Project Catalyst

This template provides a security-hardened, production-ready environment for ComfyUI with FLUX models, featuring advanced download management and forensic cleanup capabilities.

### 🌟 Key Features:
- **Security-First Design**: Built with Docker security best practices, non-root execution, and optional forensic cleanup.
- **Robust Download Manager**: Integrated Nexis download manager with checksum validation, retry logic, and atomic file operations.
- **Advanced Model Support**: Seamless integration with HuggingFace transformers and CivitAI models with proper organization.
- **Flexible Security Modes**: Configurable security levels from public to paranoid mode with network isolation.
- **Modern GPU Optimization**: Built on CUDA 12.8 with PyTorch 2.7+ for RTX 40/50 series performance.

### 🖥️ Services & Ports:
- **ComfyUI**: Port `8188`
- **FileBrowser**: Port `8080` (if enabled)

### ⚙️ Environment Variables (See Template Options):
- **Downloads**: `HF_REPOS_TO_DOWNLOAD`, `CIVITAI_CHECKPOINTS_TO_DOWNLOAD`, `CIVITAI_LORAS_TO_DOWNLOAD`, `CIVITAI_VAES_TO_DOWNLOAD`
- **Security**: `NETWORK_MODE`, `SECURITY_LEVEL`, `PARANOID_MODE`, `ENABLE_FORENSIC_CLEANUP`
- **Debug**: `DEBUG_MODE` for detailed logging and troubleshooting
- All API tokens are configured via RunPod Secrets for maximum security.

### 🛡️ Security Highlights:
- **Hardened Container**: Runs with `--security-opt=no-new-privileges --cap-drop=ALL`
- **Forensic Cleanup**: Optional secure deletion of all traces on container shutdown
- **Network Security**: Configurable network isolation modes (public/restricted/paranoid)
- **Checksum Validation**: All downloads verified against official hashes to prevent tampering

### 🧰 Technical Specifications:
- **Base Image**: `nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04`
- **Python**: 3.11 with optimized virtual environment
- **Default Temp Storage**: 200 GB container, 100 GB volume
- **Security**: Non-root execution, capability dropping, privilege escalation prevention
EOF
)

# ─── GraphQL Definition ─────────────────────────────────────────────────────
GRAPHQL_QUERY=$(cat <<'EOF'
mutation saveTemplate($input: SaveTemplateInput!) {
  saveTemplate(input: $input) {
    id
    name
    imageName
  }
}
EOF
)

# ─── API Payload Construction ───────────────────────────────────────────────
# Build the final JSON payload using jq for safety and correctness.
PAYLOAD=$(jq -n \
  --arg name "$TEMPLATE_NAME" \
  --arg imageName "$IMAGE_NAME" \
  --argjson cDisk 200 \
  --argjson vGb 100 \
  --arg vPath "/runpod-volume" \
  --arg dArgs "$docker_args" \
  --arg ports "8188/http" \
  --arg readme "$README_CONTENT" \
  --arg query "$GRAPHQL_QUERY" \
  '{
    "query": $query,
    "variables": {
      "input": {
        "name": $name,
        "imageName": $imageName,
        "containerDiskInGb": $cDisk,
        "volumeInGb": $vGb,
        "volumeMountPath": $vPath,
        "dockerArgs": $dArgs,
        "ports": $ports,
        "readme": $readme,
        "env": [
          { "key": "DEBUG_MODE", "value": "false" },
          { "key": "COMFYUI_FLAGS", "value": "--bf16-unet --highvram --gpu-only" },
          { "key": "FB_USERNAME", "value": "admin" },
          { "key": "FB_PASSWORD", "value": "{{ RUNPOD_SECRET_FILEBROWSER_PASSWORD }}" },
          { "key": "HUGGINGFACE_TOKEN", "value": "{{ RUNPOD_SECRET_huggingface.co }}" },
          { "key": "CIVITAI_TOKEN", "value": "{{ RUNPOD_SECRET_civitai.com }}" },
          { "key": "HF_REPOS_TO_DOWNLOAD", "value": "black-forest-labs/FLUX.1-dev" },
          { "key": "CIVITAI_CHECKPOINTS_TO_DOWNLOAD", "value": "1569593,919063,450105" },
          { "key": "CIVITAI_LORAS_TO_DOWNLOAD", "value": "182404,445135,871108" },
          { "key": "CIVITAI_VAES_TO_DOWNLOAD", "value": "1674314" },
          { "key": "DOWNLOAD_TIMEOUT", "value": "3600" },
          { "key": "VERIFY_CHECKSUMS", "value": "true" },
          { "key": "NETWORK_MODE", "value": "public" },
          { "key": "SECURITY_LEVEL", "value": "normal" },
          { "key": "PARANOID_MODE", "value": "false" },
          { "key": "ENABLE_FORENSIC_CLEANUP", "value": "false" },
          { "key": "SECURITY_TOKEN_VAULT_PATH", "value": "/run/secrets/token" },
          { "key": "PYTHONPATH", "value": "/home/comfyuser/workspace/ComfyUI" },
          { "key": "CUDA_VISIBLE_DEVICES", "value": "all" },
          { "key": "NVIDIA_VISIBLE_DEVICES", "value": "all" },
          { "key": "OMP_NUM_THREADS", "value": "8" },
          { "key": "PYTORCH_CUDA_ALLOC_CONF", "value": "max_split_size_mb:1024" },
          { "key": "CUDA_LAUNCH_BLOCKING", "value": "0" },
          { "key": "CONTAINER_USER", "value": "comfyuser" },
          { "key": "CONTAINER_UID", "value": "1000" },
          { "key": "CONTAINER_GID", "value": "1000" }
        ]
      }
    }
  }')

# ─── API Request ────────────────────────────────────────────────────────────
echo "🚀 Sending request to create/update RunPod template..."
echo "   Template Name: $TEMPLATE_NAME"
echo "   Docker Image:  $IMAGE_NAME"

response=$(curl -s -w "\n%{http_code}" \
  -X POST "https://api.runpod.io/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -H "User-Agent: Project-Catalyst-Deploy/1.0" \
  -d "$PAYLOAD")

# ─── Response Handling ──────────────────────────────────────────────────────
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$http_code" -ne 200 ]; then
  echo "❌ HTTP $http_code returned from RunPod API." >&2
  echo "$body" | jq . >&2
  exit 1
fi

template_id=$(echo "$body" | jq -r '.data.saveTemplate.id')
if [ -z "$template_id" ] || [ "$template_id" = "null" ]; then
  echo "❌ Error: Template creation failed. Response from API:" >&2
  echo "$body" | jq . >&2
  exit 1
fi

echo "✅ Template '$TEMPLATE_NAME' created/updated successfully!"
echo "   ID: $template_id"
echo "🎉 You can now find your template in the RunPod console."