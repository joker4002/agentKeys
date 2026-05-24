#!/usr/bin/env bash
# pm/scripts/check-workflows.sh
# Read-only: audits the workflows on litentry/projects/19 against expected-workflows.json.
#
# IMPORTANT LIMITATION: GitHub's public GraphQL API exposes only the workflow's
# name + enabled state, NOT the filter expression or action configuration.
# So this script can verify "the right workflows are enabled" but NOT "they're
# configured to do the right thing." Filter/action contents must still be
# verified in the UI: https://github.com/orgs/litentry/projects/19/workflows
#
# Requires: gh auth refresh -s project,read:project (one-time)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_JSON="$SCRIPT_DIR/../expected-workflows.json"
PROJECT_OWNER="${PROJECT_OWNER:-litentry}"
PROJECT_NUMBER="${PROJECT_NUMBER:-19}"

if [ ! -f "$EXPECTED_JSON" ]; then
  echo "fail expected-workflows.json not found at $EXPECTED_JSON"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fail jq not installed"
  exit 1
fi

if ! gh project list --owner "$PROJECT_OWNER" >/dev/null 2>&1; then
  echo "fail missing project scopes; run: gh auth refresh -s project,read:project"
  exit 1
fi

echo "=== Workflow audit: $PROJECT_OWNER/projects/$PROJECT_NUMBER ==="
echo ""

# Fetch live workflows via GraphQL
live_json=$(gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        workflows(first: 50) {
          nodes { id name enabled number updatedAt }
        }
      }
    }
  }
' -F "owner=$PROJECT_OWNER" -F "number=$PROJECT_NUMBER")

mismatches=0
matches=0

# For each expected workflow, find it in live state + report
while IFS= read -r expected; do
  name=$(echo "$expected" | jq -r '.name')
  expected_enabled=$(echo "$expected" | jq -r '.should_be_enabled')
  purpose=$(echo "$expected" | jq -r '.purpose')
  verify=$(echo "$expected" | jq -r '.verify_in_ui')

  live=$(echo "$live_json" | jq -c --arg n "$name" '.data.organization.projectV2.workflows.nodes[] | select(.name == $n)')

  if [ -z "$live" ]; then
    # Not found = effectively disabled. Only flag as mismatch if expected to be enabled.
    if [ "$expected_enabled" = "true" ]; then
      echo "MISSING: '$name' — expected enabled but workflow does not exist on project"
      mismatches=$((mismatches + 1))
    else
      echo "ok       '$name' (not enabled — expected)"
      matches=$((matches + 1))
    fi
    continue
  fi

  live_enabled=$(echo "$live" | jq -r '.enabled')

  if [ "$live_enabled" = "$expected_enabled" ]; then
    echo "ok       '$name' (enabled=$live_enabled)"
    matches=$((matches + 1))
  else
    echo "MISMATCH '$name' — expected enabled=$expected_enabled, live enabled=$live_enabled"
    echo "         purpose: $purpose"
    mismatches=$((mismatches + 1))
  fi
done < <(jq -c '.expected[]' "$EXPECTED_JSON")

echo ""
echo "=== Live workflows not in expected list ==="
while IFS= read -r live_name; do
  in_expected=$(jq --arg n "$live_name" '.expected | map(select(.name == $n)) | length' "$EXPECTED_JSON")
  if [ "$in_expected" = "0" ]; then
    echo "UNEXPECTED: '$live_name' is live but not in expected-workflows.json — add it or document why"
  fi
done < <(echo "$live_json" | jq -r '.data.organization.projectV2.workflows.nodes[].name')

echo ""
echo "=== Manual verification needed (NOT introspectable via API) ==="
echo "GitHub does not expose workflow filter/action configuration via the public API."
echo "For each ENABLED workflow above, verify the configuration matches the 'verify_in_ui'"
echo "note in expected-workflows.json by opening:"
echo ""
echo "  https://github.com/orgs/$PROJECT_OWNER/projects/$PROJECT_NUMBER/workflows"
echo ""
echo "Per-workflow expected configurations:"
jq -r '.expected[] | "  - " + .name + ": " + .verify_in_ui' "$EXPECTED_JSON"

echo ""
if [ "$mismatches" -eq 0 ]; then
  echo "ok check-workflows: $matches matched, 0 mismatches"
  exit 0
else
  echo "fail check-workflows: $matches matched, $mismatches mismatch(es) — see above"
  exit 1
fi
