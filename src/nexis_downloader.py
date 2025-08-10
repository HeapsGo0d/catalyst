#!/usr/bin/env python3
"""
Nexis Download Manager - Python Implementation
Combines Hearmeman's reliable CivitAI approach with Phoenix's parallel processing capabilities
"""

import os
import json
import sys
import shutil
import subprocess
from pathlib import Path

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
            total=5,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "OPTIONS"],
            respect_retry_after_header=True,
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        return session

    def _require_tools(self, *tools: str) -> bool:
        """Ensure required CLI tools exist in PATH."""
        missing = [t for t in tools if not shutil.which(t)]
        if missing:
            self.log(f"❌ Required tools not found: {', '.join(missing)}")
            return False
        return True

    def log(self, message: str, is_debug: bool = False) -> None:
        """Logging function with debug support."""
        if is_debug and not self.debug_mode:
            return
        prefix = "[DOWNLOAD-DEBUG]" if is_debug else "[DOWNLOAD]"
        print(f"  {prefix} {message}")

    # ---------- Hugging Face ----------

    def download_hf_repos(self, repos_list: str, token: str | None = None) -> tuple[int, int]:
        """Download HuggingFace repositories using huggingface-cli."""
        if not repos_list:
            self.log("No Hugging Face repos specified to download.")
            return (0, 0)

        if not self._require_tools("huggingface-cli"):
            return (0, 1)

        self.log("Found Hugging Face repos to download...")
        repos = [repo.strip() for repo in repos_list.split(",") if repo.strip()]

        # Create huggingface subdirectory
        hf_dir = self.download_tmp_dir / "huggingface"
        hf_dir.mkdir(exist_ok=True)

        ok, fail = 0, 0
        for repo_id in repos:
            self.log(f"Starting HF download: {repo_id}")

            cmd = [
                "huggingface-cli",
                "download",
                repo_id,
                "--local-dir",
                str(hf_dir / repo_id),
                "--local-dir-use-symlinks",
                "False",
                "--resume-download",
            ]
            if token:
                cmd.extend(["--token", token])
                self.log("Using provided HuggingFace token", is_debug=True)
            else:
                self.log("No HuggingFace token provided", is_debug=True)

            try:
                self.log(f"Executing command: {' '.join(cmd[:-1])} <repo>", is_debug=True)
                result = subprocess.run(
                    cmd,
                    check=True,
                    capture_output=not self.debug_mode,
                    text=True,
                )
                self.log(f"Subprocess finished with exit code {result.returncode}", is_debug=True)
                self.log(f"✅ Completed HF download: {repo_id}")
                ok += 1
            except subprocess.CalledProcessError as e:
                self.log(f"❌ ERROR: Failed to download '{repo_id}'.")
                if not token:
                    self.log("   HINT: Likely a private/gated repository. Provide HUGGINGFACE_TOKEN.")
                else:
                    self.log("   HINT: Check your token and repo access.")
                self.log("   ⏭️ Continuing with remaining downloads...")
                if self.debug_mode and e.stderr:
                    self.log(f"stderr: {e.stderr.strip()}", is_debug=True)
                fail += 1

        return (ok, fail)

    # ---------- CivitAI ----------

    def get_civitai_model_info(self, model_id: str, token: str | None = None) -> dict | None:
        """Get model info from CivitAI API using model-versions endpoint."""
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        api_url = f"https://civitai.com/api/v1/model-versions/{model_id}"
        self.log(f"Fetching metadata from: {api_url}", is_debug=True)

        try:
            response = self.session.get(api_url, headers=headers, timeout=30)
            response.raise_for_status()

            if response.status_code == 200:
                data = response.json()
                files = data.get("files") or []
                if files:
                    file_info = files[0]
                    sha = (file_info.get("hashes") or {}).get("SHA256", "")
                    return {
                        "filename": file_info.get("name"),
                        "download_url": f"https://civitai.com/api/download/models/{model_id}?type=Model&format=SafeTensor",
                        "hash": sha.strip().lower(),
                    }

            self.log(f"Invalid API response structure for model {model_id}", is_debug=True)
            return None

        except requests.RequestException as e:
            self.log(f"API request failed for model {model_id}: {e}", is_debug=True)
            return None

    def download_civitai_model(self, model_id: str, model_type: str, token: str | None = None) -> bool:
        """Download a single model from CivitAI using aria2c with Authorization header."""
        if not model_id:
            return True

        if not self._require_tools("aria2c", "sha256sum"):
            return False

        self.log(f"Processing Civitai model ID: {model_id}", is_debug=True)

        # Get model info
        model_info = self.get_civitai_model_info(model_id, token)
        if not model_info or not model_info.get("filename"):
            self.log(f"❌ ERROR: Could not retrieve metadata for Civitai model ID {model_id}.")
            return False

        filename = model_info["filename"]
        download_url = model_info["download_url"]
        remote_hash = model_info["hash"]

        self.log(f"Filename: {filename}", is_debug=True)
        self.log(f"Download URL: {download_url}", is_debug=True)

        # Create model type subdirectory
        model_dir = self.download_tmp_dir / model_type.lower()
        model_dir.mkdir(exist_ok=True)

        output_file = model_dir / filename
        if output_file.exists() and output_file.stat().st_size > 0:
            self.log(f"ℹ️ Skipping download for '{filename}', file already exists in downloads.")
            return True

        self.log(f"Starting Civitai download: {filename} ({model_type})")

        # Use header for token; avoid leaking in URLs/process list
        headers = []
        if token and token.strip():
            headers += [f"--header=Authorization: Bearer {token.strip()}"]
            self.log("Using Authorization header for CivitAI", is_debug=True)

        cmd = [
            "aria2c",
            "-x",
            "8",
            "-s",
            "8",
            "--continue=true",
            "--console-log-level=info" if self.debug_mode else "--console-log-level=warn",
            "--summary-interval=10" if self.debug_mode else "--summary-interval=0",
            f"--dir={model_dir}",
            f"--out={filename}",
            *headers,
            download_url,
        ]

        try:
            self.log(f"Executing command: {' '.join(cmd[:-1])} <url>", is_debug=True)
            result = subprocess.run(
                cmd,
                check=True,
                capture_output=not self.debug_mode,
                text=True,
            )
            self.log(f"Subprocess finished with exit code {result.returncode}", is_debug=True)
            self.log(f"✅ Download completed for {filename}")

            # Verify checksum if available
            if remote_hash:
                self.log(f"Verifying checksum for {filename}...", is_debug=True)
                if self._verify_checksum(output_file, remote_hash):
                    self.log(f"✅ Checksum verification PASSED for {filename}.")
                else:
                    self.log(f"❌ DOWNLOAD ERROR: Checksum verification FAILED for {filename}.")
                    self.log("   Removing corrupted file and marking download as failed.")
                    try:
                        output_file.unlink(missing_ok=True)
                    except Exception:
                        pass
                    return False
            else:
                self.log(f"No checksum available for {filename}, skipping validation", is_debug=True)

            self.log(f"✅ Successfully completed Civitai download: {filename}")
            return True

        except subprocess.CalledProcessError as e:
            self.log(f"❌ DOWNLOAD ERROR: Failed to download {filename} from Civitai.")
            self.log(f"   aria2c exit code: {e.returncode}")
            if self.debug_mode and e.stderr:
                self.log(f"   stderr: {e.stderr.strip()}", is_debug=True)

            if output_file.exists():
                self.log(f"   Removing partial download file: {filename}")
                try:
                    output_file.unlink(missing_ok=True)
                except Exception:
                    pass

            stderr_s = (e.stderr or "").lower() if isinstance(e.stderr, str) else ""
            if "403" in stderr_s or "forbidden" in stderr_s:
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

            result = subprocess.run(
                ["sha256sum", str(file_path)],
                capture_output=True,
                text=True,
                check=True,
            )
            actual_hash = result.stdout.split()[0].lower()
            expected_hash_clean = expected_hash.strip().lower()

            if actual_hash == expected_hash_clean:
                self.log(f"✅ Checksum verification passed for {file_path.name}", is_debug=True)
                return True
            else:
                self.log(f"❌ CHECKSUM MISMATCH for {file_path.name}:")
                self.log(f"   Expected: {expected_hash_clean}")
                self.log(f"   Actual:   {actual_hash}")
                return False

        except subprocess.CalledProcessError as e:
            self.log(f"❌ CHECKSUM ERROR: sha256sum command failed for {file_path.name}")
            self.log(f"   Command error: {e}")
            if e.stderr:
                self.log(f"   stderr: {e.stderr.strip()}")
            return False
        except FileNotFoundError:
            self.log("❌ CHECKSUM ERROR: sha256sum not found. Please ensure coreutils is installed.")
            return False
        except IndexError:
            self.log(f"❌ CHECKSUM ERROR: Invalid sha256sum output for {file_path.name}")
            return False
        except Exception as e:
            self.log(f"❌ CHECKSUM ERROR: Unexpected error for {file_path.name}: {e}")
            return False

    def process_civitai_downloads(
        self, download_list: str, model_type: str, token: str | None = None
    ) -> tuple[int, int]:
        """Process comma-separated list of CivitAI model IDs."""
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

    # ---------- FS ----------

    def create_directory_structure(self) -> None:
        """Create organized directory structure in downloads_tmp."""
        for dir_name in ("checkpoints", "loras", "vae", "huggingface"):
            dir_path = self.download_tmp_dir / dir_name
            dir_path.mkdir(exist_ok=True)
            self.log(f"Created directory: {dir_path}", is_debug=True)


def main() -> int:
    """Main download orchestration."""
    # Env
    debug_mode = os.getenv("DEBUG_MODE", "false").lower() == "true"
    hf_repos = os.getenv("HF_REPOS_TO_DOWNLOAD", "")
    hf_token = os.getenv("HUGGINGFACE_TOKEN", "")
    civitai_token = os.getenv("CIVITAI_TOKEN", "")
    civitai_checkpoints = os.getenv("CIVITAI_CHECKPOINTS_TO_DOWNLOAD", "")
    civitai_loras = os.getenv("CIVITAI_LORAS_TO_DOWNLOAD", "")
    civitai_vaes = os.getenv("CIVITAI_VAES_TO_DOWNLOAD", "")

    # Init
    downloader = NexisDownloader(debug_mode=debug_mode)
    downloader.log("Initializing Nexis Python download manager...")

    if debug_mode:
        downloader.log("Debug mode enabled - showing detailed progress", is_debug=True)
        downloader.log(f"HF_REPOS_TO_DOWNLOAD: {hf_repos or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_CHECKPOINTS_TO_DOWNLOAD: {civitai_checkpoints or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_LORAS_TO_DOWNLOAD: {civitai_loras or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_VAES_TO_DOWNLOAD: {civitai_vaes or '<empty>'}", is_debug=True)

    # Prepare FS
    downloader.create_directory_structure()

    # Execute
    hf_ok, hf_fail = downloader.download_hf_repos(hf_repos, hf_token)
    ck_ok, ck_fail = downloader.process_civitai_downloads(civitai_checkpoints, "checkpoints", civitai_token)
    lr_ok, lr_fail = downloader.process_civitai_downloads(civitai_loras, "loras", civitai_token)
    va_ok, va_fail = downloader.process_civitai_downloads(civitai_vaes, "vae", civitai_token)

    downloader.log("All downloads complete.")

    # Debug summary (filesystem)
    if debug_mode:
        downloader.log("=== DOWNLOAD SUMMARY ===", is_debug=True)
        try:
            files = [f for f in downloader.download_tmp_dir.rglob("*") if f.is_file()]
            if files:
                downloader.log("Sample files:", is_debug=True)
                for file in files[:10]:
                    try:
                        size_result = subprocess.run(
                            ["ls", "-lh", str(file)],
                            capture_output=True,
                            text=True,
                        )
                        if size_result.returncode == 0:
                            downloader.log(f"  {size_result.stdout.strip()}", is_debug=True)
                    except Exception as e:
                        downloader.log(f"Failed to stat {file.name}: {type(e).__name__}: {e}", is_debug=True)
                if len(files) > 10:
                    downloader.log(f"  ... and {len(files) - 10} more files", is_debug=True)

                try:
                    size_result = subprocess.run(
                        ["du", "-sh", str(downloader.download_tmp_dir)],
                        capture_output=True,
                        text=True,
                    )
                    if size_result.returncode == 0:
                        total_size = size_result.stdout.split()[0]
                        downloader.log(f"Total download size: {total_size}", is_debug=True)
                except Exception as e:
                    downloader.log(f"Failed to calculate total size: {type(e).__name__}: {e}", is_debug=True)
            else:
                downloader.log("No files downloaded", is_debug=True)
        except Exception as e:
            downloader.log(f"Error generating summary: {e}", is_debug=True)
        downloader.log("=== END SUMMARY ===", is_debug=True)

    # Exit code: non-zero if any failures
    total_fail = hf_fail + ck_fail + lr_fail + va_fail
    return 0 if total_fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
