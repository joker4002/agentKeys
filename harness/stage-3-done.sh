#!/bin/bash
set -euo pipefail
export AGENTKEYS_SESSION_STORE=file
echo "=== Stage 3 Verification ==="

echo "--- cargo build -p agentkeys-daemon -p agentkeys-mcp ---"
cargo build -p agentkeys-daemon -p agentkeys-mcp

echo "--- cargo test -p agentkeys-daemon --test daemon_tests ---"
OUTPUT=$(cargo test -p agentkeys-daemon --test daemon_tests 2>&1)
echo "$OUTPUT"

EXPECTED=13
COUNT=$(echo "$OUTPUT" | grep "test result:" | grep -oE '[0-9]+ passed' | awk '{sum += $1} END {print sum}')
COUNT=${COUNT:-0}

echo "=== Stage 3: $COUNT / $EXPECTED tests passed ==="
if [ "$COUNT" -ge "$EXPECTED" ]; then
    echo "STAGE 3 PASSED"
    exit 0
else
    echo "STAGE 3 FAILED ($COUNT < $EXPECTED)"
    exit 1
fi
