#!/bin/bash
set -e

# --- Configuration ---
RUNPOD_API_KEY="${RUNPOD_API_KEY}"
TEMPLATE_NAME="Catalyst-Template"
DOCKER_IMAGE="HeapsGo0d/catalyst"
LOG_PREFIX="[RunPod-Template]"

# --- Helper Functions ---
log() {
    echo "$LOG_PREFIX $1"
}

# --- Main Execution ---
if [ -z "$RUNPOD_API_KEY" ]; then
    log "Error: RUNPOD_API_KEY environment variable is not set."
    exit 1
fi

log "Preparing to create or update RunPod template: ${TEMPLATE_NAME}"

# Define the GraphQL mutation
read -r -d '' GQL_MUTATION << EOM
mutation {
    saveTemplate(
        input: {
            name: "${TEMPLATE_NAME}",
            imageName: "${DOCKER_IMAGE}",
            isServerless: false,
            containerDiskInGb: 10,
            dockerArgs: "",
            env: [
                { key: "CIVITAI_MODEL_IDS", value: "" },
                { key: "ENABLE_FILEBROWSER", value: "true" },
                { key: "PREVIEW_METHOD", value: "auto" },
                { key: "ENABLE_CUDA_MALLOC", value: "true" }
            ],
            startScript: "/opt/catalyst/src/start_script.sh"
        }
    ) {
        id
        name
        imageName
    }
}
EOM

# Remove newlines and escape quotes for the JSON payload
JSON_PAYLOAD=$(echo "${GQL_MUTATION}" | tr -d '\n' | sed 's/"/\\"/g')

log "Sending GraphQL mutation to RunPod API..."

# Make the API call
response=$(curl -s -X POST \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"${JSON_PAYLOAD}\"}" \
    "https://api.runpod.io/graphql")

# Check for errors in the response
if echo "$response" | jq -e '.errors' > /dev/null; then
    log "Error creating/updating template. API Response:"
    echo "$response" | jq
    exit 1
fi

log "Template '${TEMPLATE_NAME}' created/updated successfully!"
log "Response:"
echo "$response" | jq