#!/bin/bash
set -euo pipefail
COMPLETED=$1
NEXT=$2
echo "=== Verifying Stage $COMPLETED ==="
bash harness/stage-${COMPLETED}-done.sh
echo "=== Advancing to Stage $NEXT ==="
jq ".current_stage = ${NEXT}" harness/progress.json > tmp.json && mv tmp.json harness/progress.json
echo "=== Ready for Stage $NEXT ==="
