#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "=== Stage 5a: Rust tests ==="
cargo test -p agentkeys-types -p agentkeys-provisioner -p agentkeys-mcp -p agentkeys-cli

echo "=== Stage 5a: TS tests ==="
npm test --prefix provisioner-scripts

echo "=== Stage 5a: grep guard — patterns have zero service strings ==="
if grep -riE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" provisioner-scripts/src/patterns/ 2>/dev/null; then
  echo "FAIL: service-specific string found in patterns/" >&2
  exit 1
fi

echo "=== Stage 5a: phantom chaos test isolated ==="
cd provisioner-scripts && npx vitest run tests/scrapers/openrouter.phantom.test.ts && cd -

echo "STAGE 5a PASSED"
