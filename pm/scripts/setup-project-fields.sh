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

# List existing fields so we can skip duplicates
existing_fields=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 \
  | jq -r '.fields[].name')

create_field() {
  local name="$1"
  local data_type="$2"
  local options="${3:-}"

  if echo "$existing_fields" | grep -Fxq "$name"; then
    echo "skip '$name' (already exists)"
    return
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
echo "     bash pm/scripts/sync-fields-from-labels.sh   (TODO: write this script)"
echo ""
echo "Once configured: the cluttered Labels column disappears; Priority and Phase"
echo "render as clean dropdowns; Status stays as the workflow column."
