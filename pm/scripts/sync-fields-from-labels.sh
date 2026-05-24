#!/usr/bin/env bash
# pm/scripts/sync-fields-from-labels.sh
# Mirrors issue labels into project single-select fields.
#
# Mapping:
#   label `priority/p0` → Priority field = Urgent
#   label `priority/p1` → Priority field = High
#   label `priority/p2` → Priority field = Medium
#   label `priority/p3` → Priority field = Low
#   label `kind/feature` → Kind field = Feature (case-insensitive match for all kind/* labels)
#   label `kind/bug` → Kind field = Bug, etc.
#   label `phase/v0`..`phase/v4` → Phase field = v0..v4 (DEPRECATED — milestones replace this;
#                                  kept here for back-compat until Phase field is removed)
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
kind_field_id=$(echo "$fields_json"     | jq -r '.data.node.fields.nodes[] | select(.name == "Kind")     | .id')
phase_field_id=$(echo "$fields_json"    | jq -r '.data.node.fields.nodes[] | select(.name == "Phase")    | .id')

# Forgiving mode: if a field is missing, warn + skip syncing that label class
# instead of aborting. Operator can add the missing field via setup-project-fields.sh
# and re-run; the existing one still gets synced today.
if [ -z "$priority_field_id" ] || [ "$priority_field_id" = "null" ]; then
  echo "warn Priority field not found — skipping priority/* label sync."
  priority_field_id=""
fi
if [ -z "$kind_field_id" ] || [ "$kind_field_id" = "null" ]; then
  echo "warn Kind field not found — skipping kind/* label sync."
  kind_field_id=""
fi
if [ -z "$phase_field_id" ] || [ "$phase_field_id" = "null" ]; then
  echo "info Phase field not found — skipping phase/* (expected once Phase is dropped)."
  phase_field_id=""
fi

if [ -z "$priority_field_id" ] && [ -z "$kind_field_id" ] && [ -z "$phase_field_id" ]; then
  echo "fail no syncable fields exist; nothing to do"
  exit 1
fi

echo "priority_field_id=${priority_field_id:-<missing>} kind_field_id=${kind_field_id:-<missing>} phase_field_id=${phase_field_id:-<missing>}"

# Build label→option-id maps (bash 3.2 compatible: parallel arrays, not associative)
priority_options=$(echo "$fields_json" | jq -c '.data.node.fields.nodes[] | select(.name == "Priority") | .options')
kind_options=$(echo "$fields_json"     | jq -c '.data.node.fields.nodes[] | select(.name == "Kind")     | .options')
phase_options=$(echo "$fields_json"    | jq -c '.data.node.fields.nodes[] | select(.name == "Phase")    | .options')

# Helper: given (label_value, options_json), return option ID matching the value (case-insensitive)
option_id_for() {
  local label_value="$1"
  local options_json="$2"
  local lower
  lower=$(echo "$label_value" | tr '[:upper:]' '[:lower:]')
  echo "$options_json" | jq -r --arg v "$lower" '.[] | select((.name | ascii_downcase) == $v) | .id' | head -n1
}

# Priority needs an explicit mapping (label "p0" → option "Urgent", not a direct name match)
priority_label_to_option_name() {
  case "$1" in
    p0) echo "Urgent" ;;
    p1) echo "High"   ;;
    p2) echo "Medium" ;;
    p3) echo "Low"    ;;
    *)  echo ""       ;;
  esac
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

  # --- Priority (explicit mapping: p0→Urgent, p1→High, p2→Medium, p3→Low) ---
  local priority_label
  priority_label=$(echo "$labels" | grep -E '^priority/' | head -n1 | sed 's|^priority/||' || true)
  if [ -n "$priority_label" ] && [ -n "$priority_field_id" ]; then
    local p_option_name
    p_option_name=$(priority_label_to_option_name "$priority_label")
    if [ -n "$p_option_name" ]; then
      local p_opt
      p_opt=$(option_id_for "$p_option_name" "$priority_options")
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
          >/dev/null && echo "ok  #$issue_num Priority=$p_option_name (from priority/$priority_label)" \
          || echo "fail #$issue_num Priority mutation"
      else
        echo "warn #$issue_num Priority option '$p_option_name' not found in field — re-run setup-project-fields.sh"
      fi
    else
      echo "warn #$issue_num unknown priority label 'priority/$priority_label' (expected p0..p3)"
    fi
  fi

  # --- Kind (direct case-insensitive match: kind/feature → Feature) ---------
  local kind_label
  kind_label=$(echo "$labels" | grep -E '^kind/' | head -n1 | sed 's|^kind/||' || true)
  if [ -n "$kind_label" ] && [ -n "$kind_field_id" ]; then
    local k_opt
    k_opt=$(option_id_for "$kind_label" "$kind_options")
    if [ -n "$k_opt" ]; then
      gh api graphql -f query='
        mutation($project: ID!, $item: ID!, $field: ID!, $opt: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
            value: { singleSelectOptionId: $opt }
          }) { projectV2Item { id } }
        }
      ' -F "project=$project_id" -F "item=$item_id" -F "field=$kind_field_id" -f "opt=$k_opt" \
        >/dev/null && echo "ok  #$issue_num Kind=$kind_label" \
        || echo "fail #$issue_num Kind mutation"
    else
      echo "warn #$issue_num kind label 'kind/$kind_label' has no matching field option"
    fi
  fi

  # --- Phase (deprecated; kept for back-compat until field removed) ---------
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
