#!/bin/bash
set -euo pipefail
export AGENTKEYS_SESSION_STORE=file
echo "=== Stage 4 Verification ==="

echo "--- cargo build --workspace ---"
cargo build --workspace

echo "--- cargo test -p agentkeys-daemon --test pair_tests ---"
OUTPUT=$(cargo test -p agentkeys-daemon --test pair_tests 2>&1)
echo "$OUTPUT"

EXPECTED=11
COUNT=$(echo "$OUTPUT" | grep "test result:" | grep -oE '[0-9]+ passed' | awk '{sum += $1} END {print sum}')
COUNT=${COUNT:-0}

echo "=== Stage 4: $COUNT / $EXPECTED tests passed ==="
if [ "$COUNT" -ge "$EXPECTED" ]; then
    echo "STAGE 4 PASSED"
    exit 0
else
    echo "STAGE 4 FAILED ($COUNT < $EXPECTED)"
    exit 1
fi
