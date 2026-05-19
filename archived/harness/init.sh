#!/bin/bash
set -euo pipefail
STAGE=${1:-0}
echo "=== AgentKeys Harness Init (Stage $STAGE) ==="
cargo build --workspace 2>&1
echo "=== Ready for Stage $STAGE ==="
