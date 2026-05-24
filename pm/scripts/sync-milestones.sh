#!/usr/bin/env bash
# pm/scripts/sync-milestones.sh
# Idempotent: creates missing milestones from milestones.json, updates description+state for existing ones.
# Per CLAUDE.md "Idempotent remote-setup rule".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MILESTONES_JSON="$SCRIPT_DIR/../milestones.json"
REPO="${PM_REPO:-litentry/agentKeys}"

if [ ! -f "$MILESTONES_JSON" ]; then
  echo "fail milestones.json not found at $MILESTONES_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fail jq not installed; install via brew/apt"
  exit 1
fi

echo "sync-milestones target=$REPO source=$MILESTONES_JSON"

# Fetch existing milestones (open + closed) by title
existing_json=$(gh api "repos/$REPO/milestones?state=all&per_page=100")

while IFS= read -r ms; do
  title=$(echo "$ms" | jq -r '.title')
  description=$(echo "$ms" | jq -r '.description')
  state=$(echo "$ms" | jq -r '.state')

  # Look up by title
  existing_number=$(echo "$existing_json" | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' | head -1)

  if [ -z "$existing_number" ] || [ "$existing_number" = "null" ]; then
    # Create
    echo "ok create '$title'"
    gh api "repos/$REPO/milestones" \
      -X POST \
      -f "title=$title" \
      -f "description=$description" \
      -f "state=$state" >/dev/null
  else
    # Check drift
    existing_desc=$(echo "$existing_json" | jq -r --arg t "$title" '.[] | select(.title == $t) | .description')
    existing_state=$(echo "$existing_json" | jq -r --arg t "$title" '.[] | select(.title == $t) | .state')

    if [ "$existing_desc" = "$description" ] && [ "$existing_state" = "$state" ]; then
      echo "skip '$title' (no drift, #$existing_number)"
    else
      echo "ok update '$title' (#$existing_number)"
      gh api "repos/$REPO/milestones/$existing_number" \
        -X PATCH \
        -f "description=$description" \
        -f "state=$state" >/dev/null
    fi
  fi
done < <(jq -c '.milestones[]' "$MILESTONES_JSON")

echo "ok sync-milestones complete"
