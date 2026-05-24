#!/usr/bin/env bash
# pm/scripts/sync-issues.sh
# Idempotent: reads issue-assignments.json, ensures each listed issue has the declared milestone + labels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSIGNMENTS_JSON="$SCRIPT_DIR/../issue-assignments.json"
REPO="${PM_REPO:-litentry/agentKeys}"

if [ ! -f "$ASSIGNMENTS_JSON" ]; then
  echo "fail issue-assignments.json not found at $ASSIGNMENTS_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fail jq not installed; install via brew/apt"
  exit 1
fi

echo "sync-issues target=$REPO source=$ASSIGNMENTS_JSON"

# Build milestone title→number lookup (needed because gh API takes numeric milestone IDs)
milestones_json=$(gh api "repos/$REPO/milestones?state=all&per_page=100")

while IFS= read -r entry; do
  issue=$(echo "$entry" | jq -r '.issue')
  milestone_title=$(echo "$entry" | jq -r '.milestone // empty')
  labels=$(echo "$entry" | jq -r '.labels[]?' | tr '\n' ',' | sed 's/,$//')
  state=$(echo "$entry" | jq -r '.state // "open"')
  note=$(echo "$entry" | jq -r '.note // empty')

  echo "--- issue #$issue ($note) ---"

  # Resolve milestone number
  milestone_number=""
  if [ -n "$milestone_title" ]; then
    milestone_number=$(echo "$milestones_json" | jq -r --arg t "$milestone_title" '.[] | select(.title == $t) | .number' | head -1)
    if [ -z "$milestone_number" ] || [ "$milestone_number" = "null" ]; then
      echo "fail milestone '$milestone_title' not found — run sync-milestones.sh first"
      continue
    fi
  fi

  # Fetch current issue state
  current=$(gh api "repos/$REPO/issues/$issue" 2>&1)
  if echo "$current" | grep -q "Not Found"; then
    echo "skip #$issue not found"
    continue
  fi

  current_state=$(echo "$current" | jq -r '.state')
  current_milestone_number=$(echo "$current" | jq -r '.milestone.number // "null"')
  current_labels=$(echo "$current" | jq -r '.labels[].name' | sort | tr '\n' ',' | sed 's/,$//')

  desired_labels=$(echo "$labels" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')

  changes=""
  args=()

  if [ -n "$milestone_number" ] && [ "$current_milestone_number" != "$milestone_number" ]; then
    args+=( -F "milestone=$milestone_number" )
    changes="$changes milestone"
  fi

  if [ "$current_labels" != "$desired_labels" ]; then
    # Clear existing labels then set desired (avoids accumulation)
    gh api "repos/$REPO/issues/$issue/labels" -X PUT --raw-field "labels=$(echo "$labels" | jq -R 'split(",")')" >/dev/null 2>&1 || \
      gh issue edit "$issue" --repo "$REPO" --remove-label "$(echo "$current_labels" | tr ',' ',')" >/dev/null 2>&1 || true
    gh issue edit "$issue" --repo "$REPO" --add-label "$labels" >/dev/null
    changes="$changes labels"
  fi

  if [ "$current_state" != "$state" ]; then
    if [ "$state" = "closed" ]; then
      gh issue close "$issue" --repo "$REPO" >/dev/null
    else
      gh issue reopen "$issue" --repo "$REPO" >/dev/null
    fi
    changes="$changes state"
  fi

  if [ ${#args[@]} -gt 0 ]; then
    gh api "repos/$REPO/issues/$issue" -X PATCH "${args[@]}" >/dev/null
  fi

  if [ -z "$changes" ]; then
    echo "skip #$issue (no drift)"
  else
    echo "ok #$issue updated:$changes"
  fi
done < <(jq -c '.assignments[]' "$ASSIGNMENTS_JSON")

echo "ok sync-issues complete"
