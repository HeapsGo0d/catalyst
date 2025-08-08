#!/usr/bin/env python3
"""
Nexis Download Manager - Python Implementation
Combines Hearmeman's reliable CivitAI approach with Phoenix's parallel processing capabilities
"""

import requests
import os
import subprocess
import sys
import json
from pathlib import Path
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


class NexisDownloader:
    def __init__(self, debug_mode=False):
        self.debug_mode = debug_mode
        self.download_tmp_dir = Path("/home/comfyuser/workspace/downloads_tmp")
        self.download_tmp_dir.mkdir(exist_ok=True)
        self.session = self._create_session()

    def _create_session(self):
        """Create a requests session with retry logic."""
        session = requests.Session()
        retry_strategy = Retry(
            total=5,
            backoff_factor=1,
            status_forcelist=,
            allowed_methods=["HEAD", "GET", "OPTIONS"]
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        return session

    def log(self, message, is_debug=False):
        """Logging function with debug support"""
        prefix = "[DOWNLOAD-DEBUG]" if is_debug else "[DOWNLOAD]"
        if is_debug and not self.debug_mode:
            return
        print(f"  {prefix} {message}")

    def download_hf_repos(self, repos_list, token=None):
        """Download HuggingFace repositories using huggingface-cli"""
        if not repos_list:
            self.log("No Hugging Face repos specified to download.")
            return True
            
        self.log("Found Hugging Face repos to download...")
        
        repos = [repo.strip() for repo in repos_list.split(',') if repo.strip()]
        
        # Create huggingface subdirectory
        hf_dir = self.download_tmp_dir / "huggingface"
        hf_dir.mkdir(exist_ok=True)
        
        for repo_id in repos:
            self.log(f"Starting HF download: {repo_id}")
            
            # Build huggingface-cli command
            cmd = [
                'huggingface-cli', 'download',
                repo_id,
                '--local-dir', str(hf_dir / repo_id),
                '--local-dir-use-symlinks', 'False',
                '--resume-download'
            ]
            
            if token:
                cmd.extend(['--token', token])
                self.log("Using provided HuggingFace token", is_debug=True)
            else:
                self.log("No HuggingFace token provided", is_debug=True)
            
            try:
                self.log(f"Executing command: {' '.join(cmd)}", is_debug=True)
                if self.debug_mode:
                    result = subprocess.run(cmd, check=True)
                else:
                    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
                self.log(f"Subprocess finished with exit code {result.returncode}", is_debug=True)
                    
                self.log(f"✅ Completed HF download: {repo_id}")
                
                if self.debug_mode:
                    # Show download size
                    try:
                        size_result = subprocess.run(['du', '-sh', str(hf_dir / repo_id)],
                                                   capture_output=True, text=True)
                        if size_result.returncode == 0:
                            size = size_result.stdout.split()
                            self.log(f"Downloaded size: {size}", is_debug=True)
                    except subprocess.CalledProcessError as e:
                        self.log(f"Failed to calculate download size for {repo_id}: subprocess error {e.returncode}", is_debug=True)
                    except Exception as e:
                        self.log(f"Failed to calculate download size for {repo_id}: {type(e).__name__}: {e}", is_debug=True)
                        
            except subprocess.CalledProcessError as e:
                self.log(f"❌ ERROR: Failed to download '{repo_id}'.")
                if not token:
                    self.log("   HINT: This is likely a private/gated repository. Please provide a")
                    self.log("   HUGGINGFACE_TOKEN via RunPod Secrets ('huggingface.co').")
                else:
                    self.log("   HINT: Please check if your token is valid and has access to this repository.")
                self.log("   ⏭️ Continuing with remaining downloads...")
                continue
                
        return True

    def get_civitai_model_info(self, model_id, token=None):
        """Get model info from CivitAI API using Hearmeman's approach"""
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
            
        # Use model-versions endpoint like Hearmeman
        api_url = f"https://civitai.com/api/v1/model-versions/{model_id}"
        
        self.log(f"Fetching metadata from: {api_url}", is_debug=True)
        
        try:
            response = self.session.get(api_url, headers=headers, timeout=30)
            response.raise_for_status()

            if response.status_code == 200:
                data = response.json()
                if 'files' in data and data['files']:
                    file_info = data['files']  # Get first file
                    return {
                        'filename': file_info.get('name'),
                        'download_url': f"https://civitai.com/api/download/models/{model_id}?type=Model&format=SafeTensor",
                        'hash': file_info.get('hashes', {}).get('SHA256', '').lower()
                    }
            
            self.log(f"Invalid API response structure for model {model_id}", is_debug=True)
            return None
            
        except requests.RequestException as e:
            self.log(f"API request failed for model {model_id}: {e}", is_debug=True)
            return None

    def download_civitai_model(self, model_id, model_type, token=None):
        """Download single model from CivitAI using Hearmeman's method with aria2c"""
        if not model_id:
            return True
            
        self.log(f"Processing Civitai model ID: {model_id}", is_debug=True)
        
        # Get model info
        model_info = self.get_civitai_model_info(model_id, token)
        if not model_info or not model_info['filename']:
            self.log(f"❌ ERROR: Could not retrieve metadata for Civitai model ID {model_id}.")
            return False
            
        filename = model_info['filename']
        download_url = model_info['download_url']
        remote_hash = model_info['hash']
        
        self.log(f"Filename: {filename}", is_debug=True)
        self.log(f"Download URL: {download_url[:50]}...", is_debug=True)
        
        # Create model type subdirectory
        model_dir = self.download_tmp_dir / model_type.lower()
        model_dir.mkdir(exist_ok=True)
        
        # Check if file already exists in download directory
        output_file = model_dir / filename
        if output_file.exists() and output_file.stat().st_size > 0:
            self.log(f"ℹ️ Skipping download for '{filename}', file already exists in downloads.")
            return True
            
        self.log(f"Starting Civitai download: {filename} ({model_type})")
        
        # Build aria2c command like Hearmeman, but add token to URL
        if token and token.strip():
            download_url += f"&token={token.strip()}"
            
        cmd = [
            'aria2c',
            '-x', '8',  # 8 connections like Hearmeman (proven reliable)
            '-s', '8',
            '--continue=true',
            '--console-log-level=warn' if not self.debug_mode else '--console-log-level=info',
            '--summary-interval=0' if not self.debug_mode else '--summary-interval=10',
            f'--dir={model_dir}',
            f'--out={filename}',
            download_url
        ]
        
        try:
            self.log(f"Executing command: {' '.join(cmd)}", is_debug=True)
            if self.debug_mode:
                self.log(f"Starting download with progress...", is_debug=True)
                
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
            self.log(f"Subprocess finished with exit code {result.returncode}", is_debug=True)
            
            self.log(f"✅ Download completed for {filename}")
            
            # Verify checksum if available
            if remote_hash:
                self.log(f"Verifying checksum for {filename}...", is_debug=True)
                if self._verify_checksum(output_file, remote_hash):
                    self.log(f"✅ Checksum verification PASSED for {filename}.")
                else:
                    self.log(f"❌ DOWNLOAD ERROR: Checksum verification FAILED for {filename}.")
                    self.log(f"   The downloaded file is corrupted or incomplete.")
                    self.log(f"   Removing corrupted file and marking download as failed.")
                    output_file.unlink(missing_ok=True)
                    return False
            else:
                self.log(f"No checksum available for {filename}, skipping validation", is_debug=True)
                
            self.log(f"✅ Successfully completed Civitai download: {filename}")
            return True
            
        except subprocess.CalledProcessError as e:
            self.log(f"❌ DOWNLOAD ERROR: Failed to download {filename} from Civitai.")
            self.log(f"   aria2c command failed with exit code {e.returncode}")
            if e.stderr and e.stderr.strip():
                self.log(f"   Error details: {e.stderr.strip()}")
            
            # Check if partial file exists and remove it
            if output_file.exists():
                self.log(f"   Removing partial download file: {filename}")
                output_file.unlink(missing_ok=True)
                
            # Provide helpful hints based on common failure scenarios
            if "403" in str(e.stderr) or "Forbidden" in str(e.stderr):
                self.log(f"   HINT: This may be a private model requiring authentication.")
                self.log(f"   Please ensure you have a valid CIVITAI_TOKEN if this is a private model.")
            elif "404" in str(e.stderr) or "Not Found" in str(e.stderr):
                self.log(f"   HINT: Model ID {model_id} may not exist or may have been removed.")
            elif "timeout" in str(e.stderr).lower() or "connection" in str(e.stderr).lower():
                self.log(f"   HINT: Network connectivity issue. The download may succeed on retry.")
                
            return False

    def _verify_checksum(self, file_path, expected_hash):
        """Verify SHA256 checksum with detailed error logging"""
        try:
            if not file_path.exists():
                self.log(f"❌ CHECKSUM ERROR: File does not exist: {file_path}")
                return False
                
            if not expected_hash or not expected_hash.strip():
                self.log(f"❌ CHECKSUM ERROR: No expected hash provided for {file_path.name}")
                return False
                
            result = subprocess.run(['sha256sum', str(file_path)],
                                  capture_output=True, text=True, check=True)
            actual_hash = result.stdout.split().lower()
            expected_hash_clean = expected_hash.lower().strip()
            
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
            self.log(f"❌ CHECKSUM ERROR: sha256sum command not found. Please ensure coreutils is installed.")
            return False
        except IndexError:
            self.log(f"❌ CHECKSUM ERROR: Invalid sha256sum output format for {file_path.name}")
            return False
        except Exception as e:
            self.log(f"❌ CHECKSUM ERROR: Unexpected error during checksum verification for {file_path.name}: {e}")
            return False

    def process_civitai_downloads(self, download_list, model_type, token=None):
        """Process comma-separated list of CivitAI model IDs"""
        if not download_list:
            self.log(f"No Civitai {model_type}s specified to download.")
            return True
            
        self.log(f"Found Civitai {model_type}s to download...")
        self.log(f"Processing list: {download_list}", is_debug=True)
        
        ids = [id.strip() for id in download_list.split(',') if id.strip()]
        successful = 0
        failed = 0
        
        for model_id in ids:
            if self.download_civitai_model(model_id, model_type, token):
                successful += 1
            else:
                failed += 1
                self.log(f"⏭️ Continuing with remaining {model_type}s...")
                
        self.log(f"Civitai {model_type}s complete: {successful} successful, {failed} failed")
        return True

    def create_directory_structure(self):
        """Create organized directory structure in downloads_tmp"""
        directories = [
            "checkpoints",
            "loras", 
            "vae",
            "huggingface"
        ]
        
        for dir_name in directories:
            dir_path = self.download_tmp_dir / dir_name
            dir_path.mkdir(exist_ok=True)
            self.log(f"Created directory: {dir_path}", is_debug=True)


def main():
    """Main download orchestration"""
    # Get environment variables
    debug_mode = os.getenv('DEBUG_MODE', 'false').lower() == 'true'
    hf_repos = os.getenv('HF_REPOS_TO_DOWNLOAD', '')
    hf_token = os.getenv('HUGGINGFACE_TOKEN', '')
    civitai_token = os.getenv('CIVITAI_TOKEN', '')
    civitai_checkpoints = os.getenv('CIVITAI_CHECKPOINTS_TO_DOWNLOAD', '')
    civitai_loras = os.getenv('CIVITAI_LORAS_TO_DOWNLOAD', '')
    civitai_vaes = os.getenv('CIVITAI_VAES_TO_DOWNLOAD', '')
    
    # Initialize downloader
    downloader = NexisDownloader(debug_mode=debug_mode)
    
    downloader.log("Initializing Nexis Python download manager...")
    
    if debug_mode:
        downloader.log("Debug mode enabled - showing detailed progress", is_debug=True)
        downloader.log(f"HF_REPOS_TO_DOWNLOAD: {hf_repos or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_CHECKPOINTS_TO_DOWNLOAD: {civitai_checkpoints or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_LORAS_TO_DOWNLOAD: {civitai_loras or '<empty>'}", is_debug=True)
        downloader.log(f"CIVITAI_VAES_TO_DOWNLOAD: {civitai_vaes or '<empty>'}", is_  debug=True)
    
    # Create directory structure
    downloader.create_directory_structure()
    
    # Process downloads in parallel-friendly order
    # HuggingFace repos first (they can run independently)
    downloader.download_hf_repos(hf_repos, hf_token)
    
    # Then CivitAI downloads (using model IDs, not URLs)
    downloader.process_civitai_downloads(civitai_checkpoints, "checkpoints", civitai_token)
    downloader.process_civitai_downloads(civitai_loras, "loras", civitai_token)
    downloader.process_civitai_downloads(civitai_vaes, "vae", civitai_token)
    
    downloader.log("All downloads complete.")
    
    # Debug summary
    if debug_mode:
        downloader.log("=== DOWNLOAD SUMMARY ===", is_debug=True)
        if downloader.download_tmp_dir.exists():
            try:
                files = list(downloader.download_tmp_dir.rglob('*'))
                files = [f for f in files if f.is_file()]
                if files:
                    downloader.log("Downloaded files:", is_debug=True)
                    for file in files[:10]:  # Show first 10 files
                        try:
                            size_result = subprocess.run(['ls', '-lh', str(file)],
                                                       capture_output=True, text=True)
                            if size_result.returncode == 0:
                                downloader.log(f"  {size_result.stdout.strip()}", is_debug=True)
                        except subprocess.CalledProcessError as e:
                            downloader.log(f"Failed to get file size for {file.name}: subprocess error {e.returncode}", is_debug=True)
                        except Exception as e:
                            downloader.log(f"Failed to get file size for {file.name}: {type(e).__name__}: {e}", is_debug=True)
                    
                    if len(files) > 10:
                        downloader.log(f"  ... and {len(files) - 10} more files", is_debug=True)
                    
                    # Total size
                    try:
                        size_result = subprocess.run(['du', '-sh', str(downloader.download_tmp_dir)],
                                                   capture_output=True, text=True)
                        if size_result.returncode == 0:
                            total_size = size_result.stdout.split()
                            downloader.log(f"Total download size: {total_size}", is_debug=True)
                    except subprocess.CalledProcessError as e:
                        downloader.log(f"Failed to calculate total download size: subprocess error {e.returncode}", is_debug=True)
                    except Exception as e:
                        downloader.log(f"Failed to calculate total download size: {type(e).__name__}: {e}", is_debug=True)
                else:
                    downloader.log("No files downloaded", is_debug=True)
            except Exception as e:
                downloader.log(f"Error generating summary: {e}", is_debug=True)
        downloader.log("=== END SUMMARY ===", is_debug=True)


if __name__ == "__main__":
    main()