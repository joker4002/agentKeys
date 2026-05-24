#!/usr/bin/env bash
# pm/scripts/add-to-project.sh
# Adds an issue (or all open) to the litentry/projects/19 GitHub Project board.
#
# PRIMARILY A BACKFILL / FALLBACK TOOL.
# For new issues going forward, prefer the project's built-in "Auto-add to project"
# workflow (configure filter = `repo:litentry/agentKeys is:issue` in Project settings).
# See pm/PROJECT-DASHBOARD-GUIDE.md "Built-in workflows" section.
#
# Use this script only when:
#   - Backfilling pre-existing issues that predate the workflow
#   - Auto-add workflow is misconfigured and you need a quick manual add
#   - Adding a specific issue from a different repo (script accepts repo override)
#
# Requires: gh auth refresh -s project,read:project (one-time)

set -euo pipefail

PROJECT_OWNER="${PROJECT_OWNER:-litentry}"
PROJECT_NUMBER="${PROJECT_NUMBER:-19}"
REPO="${PM_REPO:-litentry/agentKeys}"

# Verify scopes
if ! gh api "user" --jq '.login' >/dev/null 2>&1; then
  echo "fail not authenticated; run: gh auth login"
  exit 1
fi

if ! gh project list --owner "$PROJECT_OWNER" >/dev/null 2>&1; then
  echo "fail missing project scopes; run: gh auth refresh -s project,read:project"
  exit 1
fi

# Get project ID
PROJECT_ID=$(gh project list --owner "$PROJECT_OWNER" --format json --limit 100 \
  | jq -r --arg n "$PROJECT_NUMBER" '.projects[] | select(.number == ($n|tonumber)) | .id')

if [ -z "$PROJECT_ID" ]; then
  echo "fail project $PROJECT_OWNER/$PROJECT_NUMBER not found"
  exit 1
fi

echo "Project ID: $PROJECT_ID"

# Mode: single issue or all open
if [ $# -gt 0 ]; then
  issues=("$@")
else
  echo "Adding all open issues..."
  # bash 3.2-portable (macOS default) — avoid `mapfile` which is bash 4+
  issues=()
  while IFS= read -r n; do
    [ -n "$n" ] && issues+=("$n")
  done < <(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq '.[].number')
fi

for issue in "${issues[@]}"; do
  url=$(gh issue view "$issue" --repo "$REPO" --json url --jq '.url')
  if gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" >/dev/null 2>&1; then
    echo "ok add #$issue → project $PROJECT_NUMBER"
  else
    echo "skip #$issue (likely already in project, or check errors above)"
  fi
done

echo "ok add-to-project complete"
