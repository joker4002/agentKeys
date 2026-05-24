#!/usr/bin/env bash
# pm/scripts/setup-project-fields.sh
# Creates the canonical project fields on litentry/projects/19 so the board can
# group/filter by typed single-value fields instead of piling all labels into one column.
#
# Idempotent: skips fields that already exist (gh project field-create fails
# on duplicate; we swallow that error).
#
# Run once after gh auth refresh -s project,read:project.

set -euo pipefail

PROJECT_OWNER="${PROJECT_OWNER:-litentry}"
PROJECT_NUMBER="${PROJECT_NUMBER:-19}"

if ! gh project list --owner "$PROJECT_OWNER" >/dev/null 2>&1; then
  echo "fail missing project scopes; run: gh auth refresh -s project,read:project"
  exit 1
fi

# Resolve project node ID (needed for delete mutation)
project_id=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json | jq -r '.id')
if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
  echo "fail could not resolve project node ID"
  exit 1
fi

# List existing fields WITH their option counts (built-in Priority/Size/etc. have
# zero options until configured — we need to detect that case + rebuild).
existing_fields_json=$(gh api graphql -f query='
  query($id: ID!) {
    node(id: $id) {
      ... on ProjectV2 {
        fields(first: 50) {
          nodes {
            ... on ProjectV2FieldCommon { id name dataType }
            ... on ProjectV2SingleSelectField { id name dataType options { id name } }
          }
        }
      }
    }
  }
' -F "id=$project_id")

# Zombie cleanup: when GitHub's deleteProjectV2Field is called on a system-reserved
# field name (notably "Priority"), GitHub renames the old field to "Project <Name>"
# instead of fully deleting it. Over time, multiple delete-recreate cycles leave
# "Project Priority", "Project Project Priority", etc. — clutter that confuses operators
# and breaks group-by-field views. Detect + delete any "Project <managed-name>" zombie.
cleanup_zombies() {
  local managed_names="Priority Phase Estimate Risk Notes"
  for n in $managed_names; do
    local zombie_name="Project $n"
    local zombie_id
    zombie_id=$(echo "$existing_fields_json" \
      | jq -r --arg zn "$zombie_name" '.data.node.fields.nodes[] | select(.name == $zn) | .id' \
      | head -n1)
    if [ -n "$zombie_id" ] && [ "$zombie_id" != "null" ]; then
      echo "info cleaning zombie field '$zombie_name' (id=$zombie_id)"
      gh api graphql -f query='
        mutation($id: ID!) {
          deleteProjectV2Field(input: { fieldId: $id }) { projectV2Field { ... on ProjectV2FieldCommon { id } } }
        }
      ' -F "id=$zombie_id" >/dev/null 2>&1 \
        || echo "warn could not delete zombie '$zombie_name'"
    fi
  done
  # Re-fetch field list after cleanup so subsequent create_field checks see current state
  existing_fields_json=$(gh api graphql -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on ProjectV2 {
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon { id name dataType }
              ... on ProjectV2SingleSelectField { id name dataType options { id name } }
            }
          }
        }
      }
    }
  ' -F "id=$project_id")
}
cleanup_zombies

create_field() {
  local name="$1"
  local data_type="$2"
  local options="${3:-}"

  local existing
  existing=$(echo "$existing_fields_json" | jq -c --arg n "$name" '.data.node.fields.nodes[] | select(.name == $n)')

  if [ -n "$existing" ]; then
    # Empty-placeholder rebuild: if a single-select field exists with zero options,
    # delete + recreate. GitHub's built-in Priority/Size fields ship empty by default,
    # so without this rebuild the sync script can never match labels to options.
    if [ "$data_type" = "SINGLE_SELECT" ] && [ -n "$options" ]; then
      local opt_count
      opt_count=$(echo "$existing" | jq '.options // [] | length')
      if [ "$opt_count" -eq 0 ]; then
        local existing_id
        existing_id=$(echo "$existing" | jq -r '.id')
        echo "info '$name' exists with zero options — deleting empty placeholder + recreating"
        gh api graphql -f query='
          mutation($id: ID!) {
            deleteProjectV2Field(input: { fieldId: $id }) { projectV2Field { ... on ProjectV2FieldCommon { id } } }
          }
        ' -F "id=$existing_id" >/dev/null 2>&1 || {
          echo "fail could not delete empty '$name' (id=$existing_id) — delete in UI + re-run"
          return
        }
        # Fall through to create
      else
        echo "skip '$name' (already exists with $opt_count options)"
        return
      fi
    else
      echo "skip '$name' (already exists)"
      return
    fi
  fi

  args=( "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "$name" --data-type "$data_type" )
  if [ -n "$options" ]; then
    args+=( --single-select-options "$options" )
  fi

  if gh project field-create "${args[@]}" >/dev/null 2>&1; then
    echo "ok create '$name' (type=$data_type${options:+ options=$options})"
  else
    echo "fail create '$name' — check gh version supports --single-select-options"
  fi
}

echo "setup-project-fields target=$PROJECT_OWNER/$PROJECT_NUMBER"

# Priority — single-select, four levels matching priority/* labels
create_field "Priority" SINGLE_SELECT "P0,P1,P2,P3"

# Phase — single-select, matches phase/* labels (one phase per issue is the norm)
create_field "Phase" SINGLE_SELECT "v0,v1,v2,v3,v4"

# Estimate — t-shirt sizes for rough sizing
create_field "Estimate" SINGLE_SELECT "XS,S,M,L,XL"

# Iteration — sprint window (project's built-in Iteration type; if not supported,
# fall back to a TEXT field that operators fill manually). gh CLI doesn't support
# ITERATION data type via flag yet (as of gh 2.40); use TEXT for now and the UI
# can later be upgraded to Iteration manually.
create_field "Iteration" TEXT

# Risk — for surfacing items that need extra scrutiny
create_field "Risk" SINGLE_SELECT "Low,Medium,High,Critical"

# Notes — free-form text for one-line context per item
create_field "Notes" TEXT

echo ""
echo "ok setup-project-fields complete"
echo ""
echo "NEXT STEPS in the project UI (https://github.com/orgs/$PROJECT_OWNER/projects/$PROJECT_NUMBER):"
echo "  1. Open a view (e.g. 'By Labels') → click ⋯ on the Labels column → 'Hide field'"
echo "  2. Click ⋯ at the top right of the view → 'Group by' → pick 'Priority' or 'Phase'"
echo "  3. Add new columns for the fields we just created (drag from the field list)"
echo "  4. To bulk-populate field values from existing labels, run:"
echo "     bash pm/scripts/sync-fields-from-labels.sh   (or trigger via Actions)"
echo "  5. Going forward: .github/workflows/pm-sync-fields-from-labels.yml syncs"
echo "     automatically when issues get labeled/relabeled — no manual step needed."
echo ""
echo "Once configured: the cluttered Labels column disappears; Priority and Phase"
echo "render as clean dropdowns; Status stays as the workflow column."
