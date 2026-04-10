#!/bin/bash
set -euo pipefail
echo "=== Stage 0 Verification ==="
echo "--- cargo build --workspace ---"
cargo build --workspace 2>&1
echo "--- cargo test -p agentkeys-types ---"
cargo test -p agentkeys-types 2>&1
echo "--- cargo test -p agentkeys-core ---"
cargo test -p agentkeys-core 2>&1
TYPES_COUNT=$(cargo test -p agentkeys-types 2>&1 | grep "test result" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
CORE_COUNT=$(cargo test -p agentkeys-core 2>&1 | grep "test result" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
TOTAL=$((TYPES_COUNT + CORE_COUNT))
echo "=== Stage 0: $TOTAL / 8 tests passed ==="
if [ "$TOTAL" -ge 8 ]; then
    echo "STAGE 0 PASSED"
    exit 0
else
    echo "STAGE 0 FAILED ($TOTAL < 8)"
    exit 1
fi
