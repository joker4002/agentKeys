#!/usr/bin/env bash
# pm/scripts/audit.sh
# Read-only: groups open issues by milestone, flags uncategorized.

set -euo pipefail

REPO="${PM_REPO:-litentry/agentKeys}"

echo "=== PM AUDIT: $REPO ==="
echo ""

# Milestones overview
echo "=== Milestones ==="
gh api "repos/$REPO/milestones?state=all&per_page=100" --jq '.[] | "M\(.number): \(.title) [\(.state)] open_issues=\(.open_issues) closed=\(.closed_issues)"'
echo ""

# Labels overview (just counts per namespace)
echo "=== Labels (counts per namespace) ==="
gh api "repos/$REPO/labels?per_page=100" --jq '.[] | .name' | \
  awk -F/ '{ if (NF>1) print $1; else print "(no-prefix)" }' | sort | uniq -c | sort -rn
echo ""

# Open issues grouped by milestone
echo "=== Open issues by milestone ==="
gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,title,milestone,labels \
  --jq '
    group_by(.milestone.title // "(no milestone)")
    | map({
        milestone: (.[0].milestone.title // "(no milestone)"),
        count: length,
        issues: map("#\(.number) \(.title)")
      })
    | sort_by(.milestone)
    | .[]
    | "\n--- \(.milestone) (\(.count)) ---\n\(.issues | join("\n"))"
  '

echo ""
echo "=== Uncategorized issues (no milestone) ==="
gh issue list --repo "$REPO" --state open --no-milestone --limit 200 \
  --json number,title \
  --jq '.[] | "#\(.number): \(.title)"' || echo "(none — all categorized)"

echo ""
echo "=== Issues missing area/* label ==="
gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,title,labels \
  --jq '.[] | select(([.labels[].name] | map(select(startswith("area/"))) | length) == 0) | "#\(.number): \(.title)"' || echo "(none — all labeled with area/*)"

echo ""
echo "ok audit complete"
