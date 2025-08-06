# Catalyst - Testing Guide

This directory contains scripts and instructions for validating the `catalyst` Docker container.

## 1. Docker Build Test

This test ensures that the Docker image can be built successfully.

**Command:**
```bash
docker build -t catalyst-test .
```
**Expected Outcome:**
The Docker image builds without any errors.

## 2. Download Verification

This test verifies that the model download functionality is working correctly.

**Steps:**
1.  Set the `CIVITAI_MODEL_IDS` environment variable.
2.  Run the container.
3.  Check the logs for download progress.
4.  Verify that the models are present in the correct directories inside the container.

## 3. RunPod Deployment Validation

This test ensures that the container can be deployed successfully to RunPod.

**Steps:**
1.  Set the `RUNPOD_API_KEY` environment variable.
2.  Execute the `template.sh` script.
3.  Verify that the template is created or updated in your RunPod account.
4.  Deploy a pod from the template and ensure it starts without errors.