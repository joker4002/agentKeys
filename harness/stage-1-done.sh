#!/bin/bash
set -euo pipefail
export AGENTKEYS_SESSION_STORE=file
echo "=== Stage 1 Verification ==="

echo "--- cargo build --workspace ---"
cargo build --workspace

echo "--- cargo test -p agentkeys-mock-server ---"
OUTPUT=$(cargo test -p agentkeys-mock-server 2>&1)
echo "$OUTPUT"

EXPECTED=37
COUNT=$(echo "$OUTPUT" | grep "test result:" | grep -oE '[0-9]+ passed' | awk '{sum += $1} END {print sum}')
COUNT=${COUNT:-0}

echo "=== Stage 1: $COUNT / $EXPECTED tests passed ==="
if [ "$COUNT" -ge "$EXPECTED" ]; then
    echo "STAGE 1 PASSED"
    exit 0
else
    echo "STAGE 1 FAILED ($COUNT < $EXPECTED)"
    exit 1
fi
