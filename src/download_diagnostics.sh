#!/bin/bash
# ==================================================================================
# CATALYST: DOWNLOAD DIAGNOSTICS SCRIPT
# ==================================================================================
# This script helps diagnose download issues with CivitAI and HuggingFace

set -euo pipefail

echo "[DIAG] === Catalyst Download Diagnostics ==="
echo ""

# --- Environment Check ---
echo "[DIAG] 1. Environment Variables:"
echo "  HF_REPOS_TO_DOWNLOAD: ${HF_REPOS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_CHECKPOINTS_TO_DOWNLOAD: ${CIVITAI_CHECKPOINTS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_LORAS_TO_DOWNLOAD: ${CIVITAI_LORAS_TO_DOWNLOAD:-<not set>}"
echo "  CIVITAI_VAES_TO_DOWNLOAD: ${CIVITAI_VAES_TO_DOWNLOAD:-<not set>}"
echo "  HUGGINGFACE_TOKEN: ${HUGGINGFACE_TOKEN:+<set (${#HUGGINGFACE_TOKEN} chars)>}"
echo "  CIVITAI_TOKEN: ${CIVITAI_TOKEN:+<set (${#CIVITAI_TOKEN} chars)>}"
echo ""

# --- Tool Check ---
echo "[DIAG] 2. Required Tools:"
for tool in curl aria2c huggingface-cli sha256sum; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool: $(which "$tool")"
  else
    echo "  ❌ $tool: NOT FOUND"
  fi
done
echo ""

# --- Network Connectivity ---
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

# --- CivitAI API Test ---
echo "[DIAG] 4. CivitAI API Test (model 1569593):"
test_model_id="1569593"
api_url="https://civitai.com/api/v1/model-versions/$test_model_id"

echo "  Testing URL: $api_url"
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
      echo "  Model name: $(echo "$body" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "N/A")"
      ;;
    401|403)
      echo "  ❌ Authentication failed - check CIVITAI_TOKEN"
      ;;
    404)
      echo "  ❌ Model not found"
      ;;
    *)
      echo "  ❌ Unexpected response"
      echo "  Body preview: $(echo "$body" | head -c 200)"
      ;;
  esac
fi
echo ""

# --- HuggingFace Test ---
echo "[DIAG] 5. HuggingFace Test:"
if [ -n "${HUGGINGFACE_TOKEN:-}" ]; then
  echo "  Testing with token: ${HUGGINGFACE_TOKEN:0:8}..."
  if curl -s -H "Authorization: Bearer $HUGGINGFACE_TOKEN" \
     "https://huggingface.co/api/repos/black-forest-labs/FLUX.1-dev" >/dev/null; then
    echo "  ✅ HuggingFace API accessible with token"
  else
    echo "  ❌ HuggingFace API failed with token"
  fi
else
  echo "  No HuggingFace token provided"
  if curl -s "https://huggingface.co/black-forest-labs/FLUX.1-dev" | grep -q "black-forest-labs"; then
    echo "  ✅ Public HuggingFace accessible"
  else
    echo "  ❌ HuggingFace not accessible"
  fi
fi
echo ""

# --- Aria2c Test ---
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

# --- File System Check ---
echo "[DIAG] 7. File System Permissions:"
test_dir="/home/comfyuser/workspace/downloads_tmp"
echo "  Test directory: $test_dir"

if [ -d "$test_dir" ]; then
  if [ -w "$test_dir" ]; then
    echo "  ✅ Directory writable"
  else
    echo "  ❌ Directory not writable"
  fi
  
  # Test file creation
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
echo ""

# --- Recommendations ---
echo "[DIAG] === Recommendations ==="

# Check for common issues
issues_found=0

if [ -z "${CIVITAI_TOKEN:-}" ]; then
  echo "  • Add CIVITAI_TOKEN for private model downloads"
  ((issues_found++))
fi

if [ -z "${HUGGINGFACE_TOKEN:-}" ]; then
  echo "  • Add HUGGINGFACE_TOKEN for private/gated model downloads"
  ((issues_found++))
fi

if ! command -v aria2c >/dev/null; then
  echo "  • Install aria2c for download support"
  ((issues_found++))
fi

if [ $issues_found -eq 0 ]; then
  echo "  ✅ No obvious configuration issues found"
  echo "  • Try running with DEBUG_MODE=true for detailed logging"
else
  echo "  Found $issues_found potential issues above"
fi

echo ""
echo "[DIAG] === End Diagnostics ==="