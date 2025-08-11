#!/usr/bin/env python3
"""
Nexis Download Manager - Python Implementation
- Robust network timing
- Proper CivitAI API usage
- One-hop redirect resolution (drop auth on presigned R2 URLs)
- Gentler retry/backoff and clear diagnostics
"""

from __future__ import annotations

import os
import sys
import shutil
import subprocess
import time
from pathlib import Path
from typing import Tuple, Optional
from urllib.parse import urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


class NexisDownloader:
    def __init__(self, debug_mode: bool = False):
        self.debug_mode = debug_mode
        self.download_tmp_dir = Path("/home/comfyuser/workspace/downloads_tmp")
        self.download_tmp_dir.mkdir(exist_ok=True)
        self.session = self._create_session()

    # ---------- infra ----------

    def _create_session(self) -> requests.Session:
        """Create a requests session with retry logic."""
        session = requests.Session()
        retry_strategy = Retry(
            total=3,                     # gentler than 5
            backoff_factor=2,            # exponential backoff
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=frozenset({"HEAD", "GET", "OPTIONS"}),
            respect_retry_after_header=True,
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        session.headers.update({"User-Agent": "Catalyst/1.0"})
        return session

    def _require_tools(self, *tools: str) -> bool:
        """Ensure required CLI tools exist in PATH."""
        missing = [t for t in tools if not shutil.which(t)]
        if missing:
            self.log(f"❌ Required tools not found: {', '.join(missing)}")
            return False
        return True

    def log(self, message: str, is_debug: bool = False) -> None:
        """Logging with optional debug gating."""
        if is_debug and not self.debug_mode:
            return
        prefix = "[DOWNLOAD-DEBUG]" if is_debug else "[DOWNLOAD]"
        print(f"  {prefix} {message}")

    def wait_for_network_ready(self, timeout: int = 60) -> bool:
        """Wait for basic network connectivity."""
        self.log("Checking network readiness...")
        test_urls = [
            "https://8.8.8.8",       # reachability
            "https://civitai.com",   # CivitAI
            "https://huggingface.co" # Hugging Face
        ]
        start = time.time()
        while time.time() - start < timeout:
            all_ready = True
            for url in test_urls:
                try:
                    r = self.session.head(url, timeout=5)
                    if r.status_code not in (200, 301, 302):
                        all_ready = False
                        break
                except Exception:
                    all_ready = False
                    break
            if all_ready:
                self.log("✅ Network connectivity confirmed")
                return True
            self.log("Waiting for network connectivity...", is_debug=True)
            time.sleep(2)
        self.log("❌ Network readiness timeout")
        return False

    def validate_tokens(self, hf_token: Optional[str], civitai_token: Optional[str]) -> Tuple[bool, bool]:
        """Validate tokens with lightweight API checks (non-fatal)."""
        hf_valid = True
        civitai_valid = True

        if hf_token:
            try:
                r = self.session.get(
                    "https://huggingface.co/api/whoami-v2",
                    headers={"Authorization": f"Bearer {hf_token}"},
                    timeout=10,
                )
                hf_valid = (r.status_code == 200)
                self.log("✅ HuggingFace token validated" if hf_valid else "❌ HuggingFace token validation failed")
            except Exception as e:
                self.log(f"HuggingFace token validation error: {e}")
                hf_valid = False

        if civitai_token:
            try:
                # Public model version – just to validate the token endpoint path
                r = self.session.get(
                    "https://civitai.com/api/v1/model-versions/128713",
                    headers={"Authorization": f"Bearer {civitai_token}"},
                    timeout=10,
                )
                civitai_valid = (r.status_code == 200)
                self.log("✅ CivitAI token validated" if civitai_valid else "❌ CivitAI token validation failed")
            except Exception as e:
                self.log(f"CivitAI token validation error: {e}")
                civitai_valid = False

        return hf_valid, civitai_valid

    # ---------- Hugging Face ----------

    def download_hf_repos(self, repos_list: str, token: Optional[str] = None) -> Tuple[int, int]:
        """Download HuggingFace repositories using huggingface-cli."""
        if not repos_list:
            self.log("No Hugging Face repos specified to download.")
            return (0, 0)
        if not self._require_tools("huggingface-cli"):
            return (0, 1)

        self.log("Found Hugging Face repos to download...")
        repos = [r.strip() for r in repos_list.split(",") if r.strip()]

        hf_dir = self.download_tmp_dir / "huggingface"
        hf_dir.mkdir(exist_ok=True)

        ok, fail = 0, 0
        for repo_id in repos:
            self.log(f"Starting HF download: {repo_id}")
            cmd = [
                "huggingface-cli", "download", repo_id,
                "--local-dir", str(hf_dir / repo_id),
                "--local-dir-use-symlinks", "False",
                "--resume-download",
            ]
            if token:
                cmd.extend(["--token", token])
                self.log("Using provided HuggingFace token", is_debug=True)
            else:
                self.log("No HuggingFace token provided", is_debug=True)

            try:
                self.log(f"Executing: {' '.join(cmd[:-1])} <repo>", is_debug=True)
                result = subprocess.run(cmd, check=True, capture_output=not self.debug_mode, text=True)
                self.log(f"Subprocess exit {result.returncode}", is_debug=True)
                self.log(f"✅ Completed HF download: {repo_id}")
                ok += 1
            except subprocess.CalledProcessError as e:
                self.log(f"❌ ERROR: Failed to download '{repo_id}'.")
                if not token:
                    self.log("   HINT: Private/gated repo. Provide HUGGINGFACE_TOKEN.")
                else:
                    self.log("   HINT: Check token/repo access.")
                if self.debug_mode and e.stderr:
                    self.log(f"stderr: {e.stderr.strip()}", is_debug=True)
                self.log("   ⏭️ Continuing…")
                fail += 1

        return (ok, fail)

    # ---------- CivitAI ----------

    def get_civitai_model_info(self, model_id: str, token: Optional[str] = None) -> Optional[dict]:
        """Get model file metadata from CivitAI."""
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        api_url = f"https://civitai.com/api/v1/model-versions/{model_id}"
        self.log(f"Fetching metadata: {api_url}", is_debug=True)

        try:
            r = self.session.get(api_url, headers=headers, timeout=30)
            r.raise_for_status()
            data = r.json()
            files = data.get("files") or []
            if not files:
                self.log(f"No files found for model {model_id}")
                return None

            primary = next((f for f in files if f.get("primary")), files[0])
            download_url = primary.get("downloadUrl") or f"https://civitai.com/api/download/models/{model_id}"
            sha = (primary.get("hashes") or {}).get("SHA256", "")

            return {
                "filename": primary.get("name"),
                "download_url": download_url,
                "hash": sha.strip().lower() if sha else "",
                "size": (primary.get("sizeKB", 0) or 0) * 1024,
            }
        except requests.RequestException as e:
            self.log(f"API request failed for model {model_id}: {e}", is_debug=True)
            return None

    def _host_is_civitai(self, url: str) -> bool:
        try:
            return urlparse(url).hostname in {"civitai.com", "www.civitai.com"}
        except Exception:
            return False

    def download_civitai_model(self, model_id: str, model_type: str, token: Optional[str] = None) -> bool:
        """Download a single model from CivitAI with error handling and redirect resolution."""
        if not model_id:
            return True
        if not self._require_tools("aria2c", "sha256sum"):
            return False

        self.log(f"Processing Civitai model ID: {model_id}", is_debug=True)

        # 1) metadata
        info = self.get_civitai_model_info(model_id, token)
        if not info or not info.get("filename"):
            self.log(f"❌ ERROR: Could not retrieve metadata for Civitai model ID {model_id}.")
            return False

        filename = info["filename"]
        download_url = info["download_url"]
        remote_hash = info["hash"]

        self.log(f"Filename: {filename}", is_debug=True)
        self.log(f"Download URL: {download_url}", is_debug=True)

        # 2) resolve one-hop redirect to presigned R2 URL
        headers_dict = {}
        if token and token.strip():
            headers_dict["Authorization"] = f"Bearer {token.strip()}"

        try:
            r = self.session.get(download_url, headers=headers_dict, allow_redirects=False, timeout=30)
            if r.status_code in (301, 302, 303, 307, 308) and "location" in r.headers:
                final_url = r.headers["location"]
                self.log("Resolved final URL for download (no auth header on R2):", is_debug=True)
                self.log(final_url, is_debug=True)
            else:
                final_url = download_url
        except Exception as e:
            self.log(f"Redirect resolution failed: {e}", is_debug=True)
            final_url = download_url

        # 3) fs
        model_dir = self.download_tmp_dir / model_type.lower()
        model_dir.mkdir(exist_ok=True)
        output_file = model_dir / filename
        if output_file.exists() and output_file.stat().st_size > 0:
            self.log(f"ℹ️ Skipping download for '{filename}', file already exists.")
            return True

        self.log(f"Starting Civitai download: {filename} ({model_type})")

        # 4) build aria2c command
        headers = []
        # Only attach Authorization when the URL is still civitai.com
        if self._host_is_civitai(final_url) and token and token.strip():
            headers.append(f"--header=Authorization: Bearer {token.strip()}")
            self.log("Using Authorization header for CivitAI", is_debug=True)

        cmd = [
            "aria2c",
            "-x", "4",
            "-s", "4",
            "--continue=true",
            "--retry-wait=5",
            "--max-tries=2",
            "--console-log-level=info" if self.debug_mode else "--console-log-level=warn",
            "--summary-interval=10" if self.debug_mode else "--summary-interval=0",
            f"--dir={model_dir}",
            f"--out={filename}",
            *headers,
            final_url,  # use the resolved URL
        ]

        # 5) execute + verify
        try:
            self.log(f"Executing: {' '.join(cmd[:-1])} <url>", is_debug=True)
            result = subprocess.run(cmd, check=True, capture_output=not self.debug_mode, text=True)
            self.log(f"Subprocess exit {result.returncode}", is_debug=True)
            self.log(f"✅ Download completed for {filename}")

            if remote_hash:
                self.log(f"Verifying checksum for {filename}...", is_debug=True)
                if self._verify_checksum(output_file, remote_hash):
                    self.log(f"✅ Checksum verification PASSED for {filename}.")
                else:
                    self.log(f"❌ DOWNLOAD ERROR: Checksum verification FAILED for {filename}.")
                    try:
                        output_file.unlink(missing_ok=True)
                    except Exception:
                        pass
                    return False
            else:
                self.log("No checksum available; skipping validation", is_debug=True)

            self.log(f"✅ Successfully completed Civitai download: {filename}")
            return True

        except subprocess.CalledProcessError as e:
            self.log(f"❌ DOWNLOAD ERROR: Failed to download {filename} from Civitai.")
            self.log(f"   aria2c exit code: {e.returncode}")
            if self.debug_mode and e.stderr:
                self.log(f"   stderr: {e.stderr.strip()}", is_debug=True)

            if output_file.exists():
                self.log(f"   Removing partial file: {filename}")
                try:
                    output_file.unlink(missing_ok=True)
                except Exception:
                    pass

            stderr_s = (e.stderr or "").lower() if isinstance(e.stderr, str) else ""
            if e.returncode == 22:
                self.log("   HINT: HTTP error — auth or URL issue.")
            elif "403" in stderr_s or "forbidden" in stderr_s:
                self.log("   HINT: Private model. Provide a valid CIVITAI_TOKEN.")
            elif "404" in stderr_s or "not found" in stderr_s:
                self.log(f"   HINT: Model ID {model_id} may not exist or was removed.")
            elif "timeout" in stderr_s or "connection" in stderr_s:
                self.log("   HINT: Network issue. Retry may succeed.")
            return False

    def _verify_checksum(self, file_path: Path, expected_hash: str) -> bool:
        """Verify SHA256 checksum with detailed error logging."""
        try:
            if not file_path.exists():
                self.log(f"❌ CHECKSUM ERROR: File does not exist: {file_path}")
                return False
            if not expected_hash or not expected_hash.strip():
                self.log(f"❌ CHECKSUM ERROR: No expected hash provided for {file_path.name}")
                return False

            result = subprocess.run(["sha256sum", str(file_path)], capture_output=True, text=True, check=True)
            actual_hash = result.stdout.split()[0].lower()
            expected_hash_clean = expected_hash.strip().lower()

            if actual_hash == expected_hash_clean:
                self.log(f"✅ Checksum OK for {file_path.name}", is_debug=True)
                return True
            else:
                self.log(f"❌ CHECKSUM MISMATCH for {file_path.name}:")
                self.log(f"   Expected: {expected_hash_clean}")
                self.log(f"   Actual:   {actual_hash}")
