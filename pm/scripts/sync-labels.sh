#!/usr/bin/env bash
# pm/scripts/sync-labels.sh
# Idempotent: creates missing labels from labels.json, updates color+description for existing ones.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABELS_JSON="$SCRIPT_DIR/../labels.json"
REPO="${PM_REPO:-litentry/agentKeys}"

if [ ! -f "$LABELS_JSON" ]; then
  echo "fail labels.json not found at $LABELS_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fail jq not installed; install via brew/apt"
  exit 1
fi

echo "sync-labels target=$REPO source=$LABELS_JSON"

# Fetch existing labels
existing_json=$(gh api "repos/$REPO/labels?per_page=100")

while IFS= read -r lbl; do
  name=$(echo "$lbl" | jq -r '.name')
  color=$(echo "$lbl" | jq -r '.color')
  description=$(echo "$lbl" | jq -r '.description')

  # Look up by name (case-sensitive match — github labels are case-insensitive but API echoes the stored case)
  exists=$(echo "$existing_json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .name' | head -1)

  if [ -z "$exists" ]; then
    # Create
    echo "ok create '$name' (color=$color)"
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description" >/dev/null
  else
    # Check drift
    existing_color=$(echo "$existing_json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .color')
    existing_desc=$(echo "$existing_json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .description')

    if [ "$existing_color" = "$color" ] && [ "$existing_desc" = "$description" ]; then
      echo "skip '$name' (no drift)"
    else
      echo "ok update '$name'"
      gh label edit "$name" --repo "$REPO" --color "$color" --description "$description" >/dev/null
    fi
  fi
done < <(jq -c '.labels[]' "$LABELS_JSON")

echo "ok sync-labels complete"
