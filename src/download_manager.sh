#!/bin/bash

echo "[DOWNLOAD-WRAPPER] Starting Python download manager..."

# Call the Python downloader
python3 /home/comfyuser/scripts/nexis_downloader.py
DOWNLOAD_EXIT_CODE=$?

if [ $DOWNLOAD_EXIT_CODE -eq 0 ]; then
    echo "[DOWNLOAD-WRAPPER] Downloads completed successfully."
else
    echo "[DOWNLOAD-WRAPPER] Downloads completed with some failures (exit code: $DOWNLOAD_EXIT_CODE)."
    echo "[DOWNLOAD-WRAPPER] Continuing with container startup..."
fi

echo "[DOWNLOAD-WRAPPER] Download manager finished."
exit 0  # Always exit 0 to continue container startup