#!/usr/bin/env python3
"""
Nexis Download Manager - Python Implementation (Idempotent Version)
- Checks final destinations before downloading
- Creates completion markers to prevent re-downloads on restart
- Direct downloads to final locations where possible
"""

from __future__ import annotations

import os
import sys
import shutil
import subprocess
import time
from pathlib import Path
from typing import Tuple, Optional, Dict
from urllib.parse import urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


class NexisDownloader:
    def __init__(self, debug_mode: bool = False):
        self.debug_mode = debug_mode
        self.download_tmp_dir = Path("/home/comfyuser/workspace/downloads_tmp")
        self.models_dir = Path("/home/comfyuser/workspace/models")
        self.download_tmp_dir.mkdir(exist_ok=True)
        self.models_dir.mkdir(exist_ok=True)
        self.session = self._create_session()
        
        # Completion marker file
        self.completion_marker = self.download_tmp_dir / ".catalyst_downloads_complete"

    # ---------- infra ----------

    def _create_session(self) -> requests.Session:
        """Create a requests session with retry logic."""
        session = requests.Session()
        retry_strategy = Retry(
            total=3,
            backoff_factor=2,
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

    def check_completion_marker(self) -> bool:
        """Check if downloads were already completed in a previous run."""
        if self.completion_marker.exists():
            self.log("✅ Found completion marker - downloads already finished")
            return True
        return False

    def create_completion_marker(self) -> None:
        """Create completion marker to indicate successful download completion."""
        try:
            self.completion_marker.write_text(f"Downloads completed at {time.ctime()}\n")
            self.log("Created completion marker", is_debug=True)
        except Exception as e:
            self.log(f"Warning: Could not create completion marker: {e}")

    def wait_for_network_ready(self, timeout: int = 60) -> bool:
        """Wait for basic network connectivity."""
        self.log("Checking network readiness...")
        test_urls = [
            "https://8.8.8.8",
            "https://civitai.com",
            "https://huggingface.co"
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

    def _check_hf_repo_exists(self, repo_id: str) -> bool:
        """Check if HF repo already exists in final location."""
        final_dir = self.models_dir / "huggingface" / repo_id
        if final_dir.exists() and any(final_dir.iterdir()):
            self.log(f"✅ HF repo '{repo_id}' already exists in final location")
            return True
        return False

    def download_hf_repos(self, repos_list: str, token: Optional[str] = None) -> Tuple[int, int]:
        """Download HuggingFace repositories directly to final locations."""
        if not repos_list:
            self.log("No Hugging Face repos specified to download.")
            return (0, 0)
        if not self._require_tools("huggingface-cli"):
            return (0, 1)

        self.log("Found Hugging Face repos to download...")
        repos = [r.strip() for r in repos_list.split(",") if r.strip()]

        # Ensure HF models directory exists
        hf_models_dir = self.models_dir / "huggingface"
        hf_models_dir.mkdir(exist_ok=True)

        ok, fail, skipped = 0, 0, 0
        for repo_id in repos:
            # Check if already exists
            if self._check_hf_repo_exists(repo_id):
                skipped += 1
                continue

            self.log(f"Starting HF download: {repo_id}")
            final_dir = hf_models_dir / repo_id
            
            cmd = [
                "huggingface-cli", "download", repo_id,
                "--local-dir", str(final_dir),
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

        if skipped > 0:
            self.log(f"Skipped {skipped} already-downloaded HF repos")
        
        return (ok, fail)

    # ---------- CivitAI ----------

    def _check_civitai_model_exists(self, filename: str, model_type: str, expected_hash: str = "") -> bool:
        """Check if CivitAI model already exists in final location."""
        final_file = self.models_dir / model_type.lower() / filename
        if not final_file.exists():
            return False
            
        # If we have a hash, verify it
        if expected_hash and expected_hash.strip():
            if self._verify_checksum(final_file, expected_hash):
                self.log(f"✅ {model_type} '{filename}' already exists and verified")
                return True
            else:
                self.log(f"⚠️ {model_type} '{filename}' exists but checksum mismatch - will re-download")
                try:
                    final_file.unlink()
                except Exception:
                    pass
                return False
        else:
            # No hash available, assume existing file is good
            self.log(f"✅ {model_type} '{filename}' already exists (no checksum verification)")
            return True

    def get_civitai_model_info(self, model_id: str, token: Optional[str] = None) -> Optional[dict]:
        """Get model file metadata from CivitAI."""
        headers: Dict[str, str] = {}
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
        """Download a single model from CivitAI directly to final location."""
        if not model_id:
            return True
        if not self._require_tools("aria2c", "sha256sum"):
            return False

        self.log(f"Processing Civitai model ID: {model_id}", is_debug=True)

        # 1) Get metadata
        info = self.get_civitai_model_info(model_id, token)
        if not info or not info.get("filename"):
            self.log(f"❌ ERROR: Could not retrieve metadata for Civitai model ID {model_id}.")
            return False

        filename = info["filename"]
        download_url = info["download_url"]
        remote_hash = info["hash"]

        self.log(f"Filename: {filename}", is_debug=True)
        self.log(f"Download URL: {download_url}", is_debug=True)

        # 2) Check if already exists
        if self._check_civitai_model_exists(filename, model_type, remote_hash):
            return True

        # 3) Resolve one-hop redirect to presigned R2 URL
        headers_dict: Dict[str, str] = {}
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

        # 4) Prepare final location
        model_dir = self.models_dir / model_type.lower()
        model_dir.mkdir(exist_ok=True)
        output_file = model_dir / filename

        self.log(f"Starting Civitai download: {filename} ({model_type})")

        # 5) Build aria2c command
        headers = []
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
            final_url,
        ]

        # 6) Execute + verify
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
                return False

        except subprocess.CalledProcessError as e:
            self.log(f"❌ CHECKSUM ERROR: sha256sum failed for {file_path.name}")
            if e.stderr:
                self.log(f"   stderr: {e.stderr.strip()}", is_debug=True)
            return False
        except Exception as e:
            self.log(f"❌ CHECKSUM ERROR: {type(e).__name__}: {e}")
            return False

    # ---------- orchestrators ----------

    def process_civitai_downloads(self, download_list: str, model_type: str, token: Optional[str] = None) -> Tuple[int, int]:
        """Process comma-separated list of CivitAI model-version IDs."""
        if not download_list:
            self.log(f"No Civitai {model_type}s specified to download.")
            return (0, 0)

        self.log(f"Found Civitai {model_type}s to download...")
        self.log(f"Processing list: {download_list}", is_debug=True)

        ids = [mid.strip() for mid in download_list.split(",") if mid.strip()]
        successful, failed = 0, 0

        for model_id in ids:
            if self.download_civitai_model(model_id, model_type, token):
                successful += 1
            else:
                failed += 1
                self.log(f"⏭️ Continuing with remaining {model_type}s...")

        self.log(f"Civitai {model_type}s complete: {successful} successful, {failed} failed")
        return (successful, failed)

    def create_directory_structure(self) -> None:
        """Create organized directory structure."""
        # Create final model directories
        for dir_name in ("checkpoints", "loras", "vae"):
            dir_path = self.models_dir / dir_name
            dir_path.mkdir(exist_ok=True)
            self.log(f"Ensured directory: {dir_path}", is_debug=True)
        
        # Create HF models directory
        hf_dir = self.models_dir / "huggingface"
        hf_dir.mkdir(exist_ok=True)
        self.log(f"Ensured directory: {hf_dir}", is_debug=True)


def main() -> int:
    """Main download orchestration with enhanced error handling and idempotency."""
    # Environment variables
    debug_mode = os.getenv("DEBUG_MODE", "false").lower() == "true"
    hf_repos = os.getenv("HF_REPOS_TO_DOWNLOAD", "")
    hf_token = os.getenv("HUGGINGFACE_TOKEN", "")
    civitai_token = os.getenv("CIVITAI_TOKEN", "")
    civitai_checkpoints = os.getenv("CIVITAI_CHECKPOINTS_TO_DOWNLOAD", "")
    civitai_loras = os.getenv("CIVITAI_LORAS_TO_DOWNLOAD", "")
    civitai_vaes = os.getenv("CIVITAI_VAES_TO_DOWNLOAD", "")

    # Initialize
    downloader = NexisDownloader(debug_mode=debug_mode)
    downloader.log("Initializing Nexis Python download manager...")

    # Check if downloads were already completed
    if downloader.check_completion_marker():
        downloader.log("All downloads already completed in previous run - skipping")
        return 0

    if debug_mode:
        downloader.log("Debug mode enabled - detailed progress on", is_debug=True)
        downloader.log(f"HF_REPOS_TO_DOWNLOAD: {hf_repos or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_CHECKPOINTS_TO_DOWNLOAD: {civitai_checkpoints or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_LORAS_TO_DOWNLOAD: {civitai_loras or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_VAES_TO_DOWNLOAD: {civitai_vaes or '<empty>'}", is_debug=True)

    # Check if any downloads are configured
    has_downloads = bool(hf_repos or civitai_checkpoints or civitai_loras or civitai_vaes)
    if not has_downloads:
        downloader.log("No downloads configured - creating completion marker and exiting")
        downloader.create_completion_marker()
        return 0

    # Network readiness
    if not downloader.wait_for_network_ready(timeout=60):
        downloader.log("❌ Network not ready, aborting downloads")
        return 1

    # Token validation (non-fatal)
    hf_valid, civitai_valid = downloader.validate_tokens(hf_token, civitai_token)
    if hf_repos and not hf_valid:
        downloader.log("⚠️ HF downloads requested but token validation failed")
    if (civitai_checkpoints or civitai_loras or civitai_vaes) and not civitai_valid:
        downloader.log("⚠️ CivitAI downloads requested but token validation failed")

    # Prepare filesystem
    downloader.create_directory_structure()

    # Execute downloads
    total_downloads = 0
    total_failures = 0

    # HuggingFace
    if hf_repos and hf_valid:
        hf_ok, hf_fail = downloader.download_hf_repos(hf_repos, hf_token)
        total_downloads += (hf_ok + hf_fail)
        total_failures += hf_fail
    elif hf_repos:
        downloader.log("Skipping HuggingFace downloads due to token validation failure")
        total_failures += len([repo.strip() for repo in hf_repos.split(",") if repo.strip()])

    # CivitAI (allow no token for public)
    if civitai_valid or not civitai_token:
        ck_ok, ck_fail = downloader.process_civitai_downloads(civitai_checkpoints, "checkpoints", civitai_token)
        lr_ok, lr_fail = downloader.process_civitai_downloads(civitai_loras, "loras", civitai_token)
        va_ok, va_fail = downloader.process_civitai_downloads(civitai_vaes, "vae", civitai_token)

        total_downloads += (ck_ok + ck_fail + lr_ok + lr_fail + va_ok + va_fail)
        total_failures += (ck_fail + lr_fail + va_fail)
    else:
        downloader.log("Skipping CivitAI downloads due to token validation failure")
        for downloads in (civitai_checkpoints, civitai_loras, civitai_vaes):
            if downloads:
                total_failures += len([mid.strip() for mid in downloads.split(",") if mid.strip()])

    downloader.log(f"All downloads complete. Total: {total_downloads}, Failures: {total_failures}")

    # Create completion marker on successful completion
    if total_failures == 0:
        downloader.create_completion_marker()
        return 0
    elif total_failures < total_downloads:
        # Partial success - still create marker to prevent full re-run
        downloader.create_completion_marker()
        return 2
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())