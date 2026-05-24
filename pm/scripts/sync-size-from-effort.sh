#!/usr/bin/env bash
# pm/scripts/sync-size-from-effort.sh
# One-shot bulk-populate of the Size project field. Parses each open issue's
# "## Effort" body section and maps to XS/S/M/L/XL. Issues without parseable
# effort default to M. Skips items already sized.
#
# Idempotent: rerun is safe (skips already-sized items).
#
# Usage:
#   bash pm/scripts/sync-size-from-effort.sh           # all open issues
#   bash pm/scripts/sync-size-from-effort.sh 103 107   # specific issues

set -euo pipefail

PROJECT_OWNER="${PROJECT_OWNER:-litentry}"
PROJECT_NUMBER="${PROJECT_NUMBER:-19}"
REPO="${PM_REPO:-litentry/agentKeys}"

if ! gh project list --owner "$PROJECT_OWNER" >/dev/null 2>&1; then
  echo "fail missing project scopes; run: gh auth refresh -s project,read:project"
  exit 1
fi

project_id=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json | jq -r '.id')

fields_json=$(gh api graphql -f query='
  query($id: ID!) {
    node(id: $id) { ... on ProjectV2 { fields(first: 50) {
      nodes { ... on ProjectV2SingleSelectField { id name options { id name } } }
    } } }
  }
' -F "id=$project_id")

size_field_id=$(echo "$fields_json" | jq -r '.data.node.fields.nodes[] | select(.name == "Size") | .id')
size_options=$(echo "$fields_json" | jq -c '.data.node.fields.nodes[] | select(.name == "Size") | .options')

if [ -z "$size_field_id" ] || [ "$size_field_id" = "null" ]; then
  echo "fail Size field not found on project"
  exit 1
fi

option_id_for_size() {
  echo "$size_options" | jq -r --arg s "$1" '.[] | select(.name == $s) | .id' | head -n1
}

# Heuristic mapping. Real-world effort estimates fall into a small set of
# canonical buckets; this captures the common cases and defaults to M when
# the body doesn't have a parseable estimate.
effort_to_size() {
  local lower
  lower=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ')
  case "$lower" in
    *"n/a"*|*"tracking issue"*|*"not engineering"*) echo "XS" ;;
    *"half day"*|*"half-day"*|*"0.5 day"*)          echo "XS" ;;
    *"1 day"*|*"one day"*|*"~1 day"*|*"day or two"*) echo "S" ;;
    *"few days"*|*"2-3 days"*|*"2 days"*|*"3 days"*) echo "S" ;;
    *"3-4 days"*|*"4 days"*|*"3-5 days"*|*"5 days"*|*"1 week"*|*"one week"*|*"~1 week"*) echo "M" ;;
    *"1-2 weeks"*|*"2 weeks"*|*"~2 week"*|*"10 days"*) echo "L" ;;
    *"3 weeks"*|*"3+ weeks"*|*"~3w"*|*"month"*) echo "XL" ;;
    *) echo "" ;;
  esac
}

# Fetch all items on the project board with their current Size
items_json=$(gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    organization(login: $owner) { projectV2(number: $number) {
      items(first: 100) {
        nodes {
          id
          content { ... on Issue { number state } }
          fieldValues(first: 30) {
            nodes { ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2FieldCommon { name } } name } }
          }
        }
      }
    } }
  }
' -F "owner=$PROJECT_OWNER" -F "number=$PROJECT_NUMBER")

# Determine target issue set
if [ $# -gt 0 ]; then
  issues=("$@")
else
  issues=()
  while IFS= read -r n; do
    [ -n "$n" ] && issues+=("$n")
  done < <(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq '.[].number')
fi

set_size_for_issue() {
  local issue_num="$1"

  local existing
  existing=$(echo "$items_json" | jq -r --arg n "$issue_num" '
    .data.organization.projectV2.items.nodes[]
    | select(.content.number == ($n|tonumber))
    | .fieldValues.nodes[] | select(.field.name == "Size") | .name
  ' | head -n1)
  if [ -n "$existing" ]; then
    echo "skip #$issue_num (Size=$existing already set)"
    return
  fi

  local item_id
  item_id=$(echo "$items_json" | jq -r --arg n "$issue_num" '
    .data.organization.projectV2.items.nodes[]
    | select(.content.number == ($n|tonumber)) | .id
  ' | head -n1)
  if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
    echo "skip #$issue_num (not on project board)"
    return
  fi

  local body
  body=$(gh issue view "$issue_num" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

  # Extract the line after ## Effort or ## Effort estimate
  local effort_line
  effort_line=$(echo "$body" | awk '/^## Effort/{flag=1; next} flag && /^[^#]/ && NF {print; exit}' | head -n1)

  local size
  size=$(effort_to_size "$effort_line")
  local source="effort-line"
  if [ -z "$size" ]; then
    size="M"
    source="default"
  fi

  local opt_id
  opt_id=$(option_id_for_size "$size")
  if [ -z "$opt_id" ]; then
    echo "fail #$issue_num — Size option '$size' not found"
    return
  fi

  gh api graphql -f query='
    mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) {
      updateProjectV2ItemFieldValue(input: { projectId: $p, itemId: $i, fieldId: $f, value: { singleSelectOptionId: $o } }) { projectV2Item { id } }
    }
  ' -F "p=$project_id" -F "i=$item_id" -F "f=$size_field_id" -f "o=$opt_id" >/dev/null \
    && echo "ok  #$issue_num Size=$size ($source: '${effort_line:0:60}')" \
    || echo "fail #$issue_num Size mutation"
}

for issue in "${issues[@]}"; do
  set_size_for_issue "$issue"
done

echo "ok sync-size-from-effort complete"
