#!/bin/bash
# ==================================================================================
# CATALYST: DOWNLOAD DIAGNOSTICS SCRIPT (quiet probe edition)
# ==================================================================================
# - Noisy CUDA/ComfyUI modules are avoided
# - Checks env/tools/network quickly
# - Verifies CivitAI API + demonstrates one-hop redirect resolution
# - Verifies Hugging Face API/public reachability
# - Tests aria2c small file download
# - Checks FS permissions including HF_HOME
# ==================================================================================

set -euo pipefail

# Enable shell trace when DEBUG_MODE=true
if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
  set -x
fi


echo "[DIAG] === Catalyst Download Diagnostics ==="
echo ""

# --- 0. Quick ComfyUI/Python quiet probe (no CUDA touching modules) ---
echo "[DIAG] 0. Python/ComfyUI quiet probe:"
PYTHON_EXEC="${PYTHON_EXEC:-/opt/venv/bin/python}"
if [ -x "$PYTHON_EXEC" ]; then
  "$PYTHON_EXEC" - <<'PY' || echo "  ⚠️ Quiet probe encountered issues (non-fatal)."
import sys, platform
print(f"  Python: {platform.python_version()}")
try:
    import torch
    print(f"  Torch: {getattr(torch, '__version__', 'unknown')}")
    # Do NOT print torch.cuda.is_available() here to avoid CUDA noise
except Exception as e:
    print(f"  Torch probe failed: {e}")

# Quiet import of safe ComfyUI modules only
sys.path.insert(0, "/home/comfyuser/workspace/ComfyUI")
for m in ("folder_paths", "utils"):
    try:
        __import__(m)
        print(f"  ✅ Imported {m}")
    except Exception as e:
        print(f"  ⚠️ Failed to import {m}: {e}")
PY
else
  echo "  ⚠️ $PYTHON_EXEC not found/executable; skipping Python probe"
fi
echo ""

# --- 1. Environment Check ---
echo "[DIAG] 1. Environment Variables:"
echo "  HF_REPOS_TO_DOWNLOAD: ${HF_REPOS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_CHECKPOINTS_TO_DOWNLOAD: ${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_LORAS_TO_DOWNLOAD: ${CIVITAI_LORAS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_VAES_TO_DOWNLOAD: ${CIVITAI_VAES_TO_DOWNLOAD:-<not set>}"
echo "  HF_HOME: ${HF_HOME:-<not set>}"
echo "  HUGGINGFACE_TOKEN: ${HUGGINGFACE_TOKEN:+<set (${#HUGGINGFACE_TOKEN} chars)>}"
echo "  CIVITAI_TOKEN: ${CIVITAI_TOKEN:+<set (${#CIVITAI_TOKEN} chars)>}"
echo ""

# --- 2. Required Tools ---
echo "[DIAG] 2. Required Tools:"
for tool in curl aria2c huggingface-cli sha256sum; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool: $(which "$tool")"
  else
    echo "  ❌ $tool: NOT FOUND"
  fi
done
echo ""

# --- 3. Network Connectivity ---
echo "[DIAG] 3. Network Connectivity:"
test_urls=(
  "https://huggingface.co"
  "https://civitai.com"
  "https://civitai.com/api/v1"
)
for url in "${test_urls[@]}"; do
  if curl -s --connect-timeout 5 --max-time 10 "$url" >/dev/null; then
    echo "  ✅ $url: reachable"
  else
    echo "  ❌ $url: unreachable"
  fi
done
echo ""

# --- 4. CivitAI API Test + Redirect Resolution Demo ---
echo "[DIAG] 4. CivitAI API Test:"
test_model_id="${CIVITAI_TEST_MODEL_ID:-1569593}"  # You can override via env
api_url="https://civitai.com/api/v1/model-versions/$test_model_id"
echo "  Testing API URL: $api_url"
if [ -n "${CIVITAI_TOKEN:-}" ]; then
  echo "  Using token: ${CIVITAI_TOKEN:0:8}..."
  response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" "$api_url" || echo "CURL_FAILED")
else
  echo "  No token provided"
  response=$(curl -s -w "\n%{http_code}" "$api_url" || echo "CURL_FAILED")
fi

if [ "$response" = "CURL_FAILED" ]; then
  echo "  ❌ Curl command failed"
else
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  echo "  HTTP Status: $http_code"
  case $http_code in
    200)
      echo "  ✅ API accessible"
      name=$(echo "$body" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      dl=$(echo "$body" | grep -o '"downloadUrl":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      echo "  Model name: ${name:-N/A}"
      echo "  downloadUrl: ${dl:-N/A}"
      # One-hop redirect resolution (noisy headers avoided; we only inspect Location)
      if [ -n "$dl" ]; then
        echo "  Resolving one-hop redirect for downloadUrl:"
        # Send Authorization only to civitai.com; curl prints redirect location with -I -s -S
        auth_header=()
        if [ -n "${CIVITAI_TOKEN:-}" ] && [[ "$dl" == https://civitai.com/* ]]; then
          auth_header=(-H "Authorization: Bearer $CIVITAI_TOKEN")
        fi
        loc=$(curl -s -I -L --max-redirs 1 "${auth_header[@]}" "$dl" | awk -F': ' '/^location:/I{print $2}' | tr -d '\r')
        if [ -n "$loc" ]; then
          host=$(echo "$loc" | awk -F/ '{print $3}')
          echo "    ➜ Final (presigned) URL host: $host"
          echo "    (Do NOT send Authorization header to this presigned host.)"
        else
          echo "    (No redirect detected; using original URL)"
        fi
      fi
      ;;
    401|403)
      echo "  ❌ Authentication failed - check CIVITAI_TOKEN"
      ;;
    404)
      echo "  ❌ Model not found (check you used a *model-version* ID)"
      ;;
    *)
      echo "  ❌ Unexpected response"
      echo "  Body preview: $(echo "$body" | head -c 200)"
      ;;
  esac
fi
echo ""

# --- 5. HuggingFace Test ---
echo "[DIAG] 5. HuggingFace Test:"
if [ -n "${HUGGINGFACE_TOKEN:-}" ]; then
  echo "  Testing with token: ${HUGGINGFACE_TOKEN:0:8}..."
  if curl -s -H "Authorization: Bearer $HUGGINGFACE_TOKEN" \
     "https://huggingface.co/api/whoami-v2" >/dev/null; then
    echo "  ✅ HuggingFace API accessible with token"
  else
    echo "  ❌ HuggingFace API failed with token"
  fi
else
  echo "  No HuggingFace token provided"
  if curl -s "https://huggingface.co/black-forest-labs/FLUX.1-dev" | grep -q "black-forest-labs"; then
    echo "  ✅ Public HuggingFace page accessible"
  else
    echo "  ❌ HuggingFace not accessible"
  fi
fi
echo ""

# --- 6. Aria2c Download Test ---
echo "[DIAG] 6. Aria2c Download Test:"
test_url="https://github.com/comfyanonymous/ComfyUI/raw/master/README.md"
test_file="/tmp/test_download.md"
echo "  Testing small download: $test_url"
if aria2c -q --console-log-level=error -d /tmp -o test_download.md "$test_url" 2>/dev/null; then
  if [ -f "$test_file" ]; then
    file_size=$(wc -c < "$test_file" 2>/dev/null || echo 0)
    echo "  ✅ Aria2c working (downloaded ${file_size} bytes)"
    rm -f "$test_file"
  else
    echo "  ❌ Aria2c completed but file not found"
  fi
else
  echo "  ❌ Aria2c test failed"
fi
echo ""

# --- 7. File System Check (incl. HF_HOME) ---
echo "[DIAG] 7. File System Permissions:"
test_dir="/home/comfyuser/workspace/downloads_tmp"
echo "  Test directory: $test_dir"
if [ -d "$test_dir" ]; then
  if [ -w "$test_dir" ]; then
    echo "  ✅ Directory writable"
  else
    echo "  ❌ Directory not writable"
  fi
  test_file="$test_dir/.catalyst_test"
  if touch "$test_file" 2>/dev/null; then
    echo "  ✅ Can create files"
    rm -f "$test_file"
  else
    echo "  ❌ Cannot create files"
  fi
else
  echo "  ❌ Directory does not exist"
fi

# HF_HOME specifics
if [ -n "${HF_HOME:-}" ]; then
  echo "  HF_HOME path: $HF_HOME"
  if mkdir -p "$HF_HOME" 2>/dev/null; then
    if [ -w "$HF_HOME" ]; then
      echo "  ✅ HF_HOME writable"
    else
      echo "  ❌ HF_HOME not writable"
    fi
  else
    echo "  ❌ Could not create HF_HOME directory"
  fi
else
  echo "  (HF_HOME not set; huggingface-cli may write to \$HOME/.cache)"
fi
echo ""

# --- Recommendations ---
echo "[DIAG] === Recommendations ==="
issues_found=0
if [ -z "${CIVITAI_TOKEN:-}" ]; then
  echo "  • Add CIVITAI_TOKEN for private model downloads"
  ((issues_found++))
fi
if [ -z "${HUGGINGFACE_TOKEN:-}" ]; then
  echo "  • Add HUGGINGFACE_TOKEN for private/gated repos"
  ((issues_found++))
fi
if ! command -v aria2c >/dev/null; then
  echo "  • Install aria2c for download support"
  ((issues_found++))
fi
if [ -z "${HF_HOME:-}" ]; then
  echo "  • Set HF_HOME to a writable path (e.g. /home/comfyuser/workspace/downloads_tmp/huggingface/.hf)"
  ((issues_found++))
fi
if [ $issues_found -eq 0 ]; then
  echo "  ✅ No obvious configuration issues found"
  echo "  • Run with DEBUG_MODE=true for detailed logging"
else
  echo "  Found $issues_found potential issues above"
fi

echo ""
echo "[DIAG] === End Diagnostics ==="
