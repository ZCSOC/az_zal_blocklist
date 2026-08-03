#!/usr/bin/env bash
# Add x to -euo when debugging -> -euox
set -euo pipefail
 
# ─── REQUIRED ENV ─────────────────────────────────────────────────────────────
# AZ_PAT, ORG, PROJECT, REPO
# ":?" fails on empty AND unset (plain `set -u` only catches unset).
: "${AZ_PAT:?AZ_PAT is empty or unset - check the secret name in the workflow}"
: "${ORG:?ORG is empty or unset}"
: "${PROJECT:?PROJECT is empty or unset}"
: "${REPO:?REPO is empty or unset}"
 
BRANCH="main"
TARGET_PATH="/ip_list"     # repo path, leading slash
SOURCE_FILE="./ip_list"    # local file to push
 
API="https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}"
CURL_OPTS=(-sS --fail-with-body -u ":${AZ_PAT}" -H "Accept: application/json")
 
[[ -s "${SOURCE_FILE}" ]] || { echo "ERROR: ${SOURCE_FILE} is missing or empty." >&2; exit 1; }
 
# ─── 1) CURRENT HEAD OBJECT ID ────────────────────────────────────────────────
REFS_URL="${API}/refs?filter=heads/${BRANCH}&api-version=6.0"
 
if ! REFS_JSON=$(curl "${CURL_OPTS[@]}" "${REFS_URL}"); then
  echo "ERROR: refs request failed. Response head:" >&2
  printf '%s\n' "${REFS_JSON:-<empty>}" | head -c 800 >&2
  exit 1
fi
 
# An HTML sign-in page here means the PAT is invalid/expired or lacks scope.
if ! OLD_OBJECT_ID=$(jq -er '.value[0].objectId' <<<"${REFS_JSON}"); then
  echo "ERROR: could not read objectId - branch '${BRANCH}' may not exist, or the" >&2
  echo "       response was not JSON (invalid PAT returns an HTML login page)." >&2
  printf '%s\n' "${REFS_JSON}" | head -c 800 >&2
  exit 1
fi
echo "Current ${BRANCH} head: ${OLD_OBJECT_ID}"
 
# ─── 2) DOES THE FILE ALREADY EXIST? (edit vs add) ────────────────────────────
ITEM_URL="${API}/items?path=${TARGET_PATH}&versionDescriptor.version=${BRANCH}&api-version=6.0"
if curl -sS -o /dev/null -u ":${AZ_PAT}" -H "Accept: application/json" \
        -w '%{http_code}' "${ITEM_URL}" | grep -q '^200$'; then
  CHANGE_TYPE="edit"
else
  CHANGE_TYPE="add"
fi
echo "changeType: ${CHANGE_TYPE}"
 
# ─── 3) BUILD THE PUSH REQUEST BODY ───────────────────────────────────────────
# Strip IPv6 (lines containing ':') and blank lines, dedupe, then JSON-escape.
FILE_CONTENT=$(
  grep -v ':' "${SOURCE_FILE}" |
  grep -v '^[[:space:]]*$' |
  sort -u |
  jq -Rs .
)
echo "Entries to push: $(grep -v ':' "${SOURCE_FILE}" | grep -cv '^[[:space:]]*$' || true)"
 
BODY=$(jq -n \
  --arg branch   "refs/heads/${BRANCH}" \
  --arg oldId    "${OLD_OBJECT_ID}" \
  --arg comment  "🔄 Auto-update ${TARGET_PATH} via REST API" \
  --arg change   "${CHANGE_TYPE}" \
  --arg path     "${TARGET_PATH}" \
  --argjson content "${FILE_CONTENT}" \
  '{
     refUpdates: [ { name: $branch, oldObjectId: $oldId } ],
     commits: [ {
       comment: $comment,
       changes: [ {
         changeType: $change,
         item: { path: $path },
         newContent: { content: $content, contentType: "rawtext" }
       } ]
     } ]
   }')
 
# ─── 4) PUSH ──────────────────────────────────────────────────────────────────
PUSH_URL="${API}/pushes?api-version=6.0"
 
if PUSH_RESP=$(curl "${CURL_OPTS[@]}" \
     -H "Content-Type: application/json" \
     -d "${BODY}" \
     "${PUSH_URL}"); then
  echo "Push succeeded. New commit: $(jq -r '.commits[0].commitId // "?"' <<<"${PUSH_RESP}")"
else
  echo "ERROR: push failed. Response:" >&2
  printf '%s\n' "${PUSH_RESP:-<empty>}" | head -c 800 >&2
  exit 1
fi
