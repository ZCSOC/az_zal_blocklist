#!/usr/bin/env bash
# Add x to -euo when debugging -> -euox
set -euo pipefail

# Use the env provided values:
# $PAT_DOPS, $ORG, $PROJECT, $REPO

# PATH inside the repo
TARGET_PATH="ip_list"

# Local file to push
SOURCE_FILE="./ip_list"

#---Fetch latest object ID---
# 1) Get the current head objectID
REFS_URL="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}/refs?filter=heads/main&api-version=6.0"
OLD_OBJECT_ID=$(curl -sS -u :${AZ_PAT} "${REFS_URL}" \
  | jq -r '.value[0].objectId')

# ─── BUILD THE PUSH REQUEST BODY ──────────────────────────────────────────────

# # Read and JSON-escape the file content
# FILE_CONTENT=$(jq -Rs . "${SOURCE_FILE}")

# Read and JSON-escape, removes duplicates and IPv6 from the file content
FILE_CONTENT=$(
  grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "${SOURCE_FILE}" |
  sort -u |
  jq -Rs .
)
# Build push payload
BODY=$(cat <<EOF
{
  "refUpdates": [
    {
      "name": "refs/heads/main",
      "oldObjectId": "${OLD_OBJECT_ID}"
    }
  ],
  "commits": [
    {
      "comment": "🔄 Auto-update ${SOURCE_FILE} via REST API",
      "changes": [
        {
          "changeType": "edit",
          "item": { "path": "${TARGET_PATH}" },
          "newContent": {
            "content": ${FILE_CONTENT},
            "contentType": "rawtext"
          }
        }
      ]
    }
  ]
}
EOF
)

# 5) Push via the REST API
PUSH_URL="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}/pushes?api-version=6.0"
if curl -sS -u :"${AZ_PAT}" \
     -H "Content-Type: application/json" \
     -d "${BODY}" \
     "${PUSH_URL}" > /dev/null; then
  echo "Push succeeded."
else
  echo "Push failed." >&2
  exit 1
fi
