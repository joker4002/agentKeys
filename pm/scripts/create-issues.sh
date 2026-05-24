#!/usr/bin/env bash
# pm/scripts/create-issues.sh
# Idempotent: creates new issues from new-issues.json. Skips if an OPEN issue with the same title already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_JSON="$SCRIPT_DIR/../new-issues.json"
REPO="${PM_REPO:-litentry/agentKeys}"

if [ ! -f "$ISSUES_JSON" ]; then
  echo "fail new-issues.json not found at $ISSUES_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fail jq not installed; install via brew/apt"
  exit 1
fi

echo "create-issues target=$REPO source=$ISSUES_JSON"

# Cache all existing open issue titles for fast dedup
existing_titles=$(gh issue list --repo "$REPO" --state all --limit 500 --json title --jq '.[].title')

created_count=0
skipped_count=0

while IFS= read -r issue; do
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body')
  milestone=$(echo "$issue" | jq -r '.milestone // empty')
  labels=$(echo "$issue" | jq -r '.labels[]?' | tr '\n' ',' | sed 's/,$//')

  # Dedup by exact title match
  if echo "$existing_titles" | grep -Fxq "$title"; then
    echo "skip '$title' (already exists)"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  args=(--repo "$REPO" --title "$title" --body "$body")
  if [ -n "$milestone" ]; then
    args+=(--milestone "$milestone")
  fi
  if [ -n "$labels" ]; then
    args+=(--label "$labels")
  fi

  url=$(gh issue create "${args[@]}" 2>&1 | tail -1)
  echo "ok create '$title' → $url"
  created_count=$((created_count + 1))
done < <(jq -c '.issues[]' "$ISSUES_JSON")

echo ""
echo "ok create-issues complete: $created_count created, $skipped_count skipped"
