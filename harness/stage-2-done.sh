#!/bin/bash
set -euo pipefail
export AGENTKEYS_SESSION_STORE=file
echo "=== Stage 2 Verification ==="

echo "--- cargo build -p agentkeys-cli ---"
cargo build -p agentkeys-cli

echo "--- cargo test -p agentkeys-cli ---"
OUTPUT=$(cargo test -p agentkeys-cli 2>&1)
echo "$OUTPUT"

EXPECTED=14
COUNT=$(echo "$OUTPUT" | grep "test result:" | grep -oE '[0-9]+ passed' | awk '{sum += $1} END {print sum}')
COUNT=${COUNT:-0}

echo "=== Stage 2: $COUNT / $EXPECTED tests passed ==="
if [ "$COUNT" -ge "$EXPECTED" ]; then
    echo "STAGE 2 PASSED"
    exit 0
else
    echo "STAGE 2 FAILED ($COUNT < $EXPECTED)"
    exit 1
fi
