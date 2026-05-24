#!/usr/bin/env bash
# pm/scripts/sync-fields-from-labels.sh
# Mirrors issue labels into project single-select fields.
#
# Mapping:
#   label `priority/p0`..`priority/p3` → Priority field = P0..P3
#   label `phase/v0`..`phase/v4`       → Phase field    = v0..v4
#
# Usage:
#   bash pm/scripts/sync-fields-from-labels.sh           # all open issues in PM_REPO
#   bash pm/scripts/sync-fields-from-labels.sh 103       # one issue
#   bash pm/scripts/sync-fields-from-labels.sh 103 104   # multiple
#
# Designed to be called from .github/workflows/pm-sync-fields-from-labels.yml
# but also runnable locally (gh auth refresh -s project,read:project).

set -euo pipefail

PROJECT_OWNER="${PROJECT_OWNER:-litentry}"
PROJECT_NUMBER="${PROJECT_NUMBER:-19}"
REPO="${PM_REPO:-litentry/agentKeys}"

if ! gh project list --owner "$PROJECT_OWNER" >/dev/null 2>&1; then
  echo "fail missing project scopes; run: gh auth refresh -s project,read:project"
  exit 1
fi

# --- One-time lookups: project node ID + field IDs + option IDs ----------------

project_id=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json \
  | jq -r '.id')

if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
  echo "fail could not resolve project node ID for $PROJECT_OWNER/projects/$PROJECT_NUMBER"
  exit 1
fi

echo "project_id=$project_id"

# Pull all field definitions in one query so we can extract Priority + Phase + their options
fields_json=$(gh api graphql -f query='
  query($id: ID!) {
    node(id: $id) {
      ... on ProjectV2 {
        fields(first: 50) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
          }
        }
      }
    }
  }
' -F "id=$project_id")

priority_field_id=$(echo "$fields_json" | jq -r '.data.node.fields.nodes[] | select(.name == "Priority") | .id')
phase_field_id=$(echo "$fields_json" | jq -r '.data.node.fields.nodes[] | select(.name == "Phase") | .id')

# Forgiving mode: if a field is missing, warn + skip syncing that label class
# instead of aborting. Operator can add the missing field via setup-project-fields.sh
# and re-run; the existing one still gets synced today.
if [ -z "$priority_field_id" ] || [ "$priority_field_id" = "null" ]; then
  echo "warn Priority field not found — skipping priority/* label sync. Run setup-project-fields.sh to enable."
  priority_field_id=""
fi
if [ -z "$phase_field_id" ] || [ "$phase_field_id" = "null" ]; then
  echo "warn Phase field not found — skipping phase/* label sync. Run setup-project-fields.sh to enable."
  phase_field_id=""
fi

if [ -z "$priority_field_id" ] && [ -z "$phase_field_id" ]; then
  echo "fail neither Priority nor Phase field exists; nothing to sync"
  exit 1
fi

echo "priority_field_id=${priority_field_id:-<missing>} phase_field_id=${phase_field_id:-<missing>}"

# Build label→option-id maps (bash 3.2 compatible: parallel arrays, not associative)
# priority/p0 → P0 option id, etc.
priority_options=$(echo "$fields_json" | jq -c '.data.node.fields.nodes[] | select(.name == "Priority") | .options')
phase_options=$(echo "$fields_json" | jq -c '.data.node.fields.nodes[] | select(.name == "Phase") | .options')

# Helper: given (label_value, options_json), return option ID matching the value (case-insensitive)
option_id_for() {
  local label_value="$1"
  local options_json="$2"
  local lower
  lower=$(echo "$label_value" | tr '[:upper:]' '[:lower:]')
  echo "$options_json" | jq -r --arg v "$lower" '.[] | select((.name | ascii_downcase) == $v) | .id' | head -n1
}

# --- Per-issue sync ------------------------------------------------------------

sync_one() {
  local issue_num="$1"

  # Resolve the item ID for this issue inside the project (skip if not on board yet).
  # Note: items(first: 100) — if the project grows past 100 items, add pagination.
  local items_json
  items_json=$(gh api graphql -f query='
    query($owner: String!, $number: Int!) {
      organization(login: $owner) {
        projectV2(number: $number) {
          items(first: 100, orderBy: {field: POSITION, direction: ASC}) {
            nodes {
              id
              content {
                ... on Issue { number }
                ... on PullRequest { number }
              }
            }
          }
        }
      }
    }
  ' -F "owner=$PROJECT_OWNER" -F "number=$PROJECT_NUMBER" 2>&1)

  if ! echo "$items_json" | jq -e '.data.organization.projectV2.items.nodes' >/dev/null 2>&1; then
    echo "fail #$issue_num could not query project items: $items_json"
    return
  fi

  local item_id
  item_id=$(echo "$items_json" \
    | jq -r --arg n "$issue_num" '.data.organization.projectV2.items.nodes[] | select(.content.number == ($n|tonumber)) | .id' \
    | head -n1)

  if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
    echo "skip #$issue_num (not on project board yet — run add-to-project.sh first)"
    return
  fi

  # Fetch labels from the issue
  local labels
  labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # --- Priority -------------------------------------------------------------
  local priority_label
  priority_label=$(echo "$labels" | grep -E '^priority/' | head -n1 | sed 's|^priority/||' || true)
  if [ -n "$priority_label" ] && [ -n "$priority_field_id" ]; then
    local p_opt
    p_opt=$(option_id_for "$priority_label" "$priority_options")
    if [ -n "$p_opt" ]; then
      gh api graphql -f query='
        mutation($project: ID!, $item: ID!, $field: ID!, $opt: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
            value: { singleSelectOptionId: $opt }
          }) { projectV2Item { id } }
        }
      ' -F "project=$project_id" -F "item=$item_id" -F "field=$priority_field_id" -f "opt=$p_opt" \
        >/dev/null && echo "ok  #$issue_num Priority=$priority_label" \
        || echo "fail #$issue_num Priority mutation"
    else
      echo "warn #$issue_num priority label '$priority_label' has no matching field option"
    fi
  fi

  # --- Phase -----------------------------------------------------------------
  local phase_label
  phase_label=$(echo "$labels" | grep -E '^phase/' | head -n1 | sed 's|^phase/||' || true)
  if [ -n "$phase_label" ] && [ -n "$phase_field_id" ]; then
    local ph_opt
    ph_opt=$(option_id_for "$phase_label" "$phase_options")
    if [ -n "$ph_opt" ]; then
      gh api graphql -f query='
        mutation($project: ID!, $item: ID!, $field: ID!, $opt: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
            value: { singleSelectOptionId: $opt }
          }) { projectV2Item { id } }
        }
      ' -F "project=$project_id" -F "item=$item_id" -F "field=$phase_field_id" -f "opt=$ph_opt" \
        >/dev/null && echo "ok  #$issue_num Phase=$phase_label" \
        || echo "fail #$issue_num Phase mutation"
    else
      echo "warn #$issue_num phase label '$phase_label' has no matching field option"
    fi
  fi

  # If neither label set, nothing to sync — silent skip
}

# --- Mode dispatch -------------------------------------------------------------

if [ $# -gt 0 ]; then
  for issue in "$@"; do
    sync_one "$issue"
  done
else
  echo "syncing all open issues in $REPO ..."
  issues=()
  while IFS= read -r n; do
    [ -n "$n" ] && issues+=("$n")
  done < <(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq '.[].number')
  for issue in "${issues[@]}"; do
    sync_one "$issue"
  done
fi

echo "ok sync-fields-from-labels complete"
