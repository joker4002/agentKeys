#!/usr/bin/env bash
# harness/scripts/sandbox-agent-isolation.sh — RUN THIS INSIDE THE AGENT SANDBOX.
#
# The REAL §10.2 agent proof that stage-3 step 11/12 cannot do from the master: the
# agent's OWN binary, signing with the device key that LIVES IN THE SANDBOX (never
# on the master), does a live memory roundtrip — cap-mint → STS (SIWE as the AGENT)
# → memory worker → S3 bots/<agent_omni>/memory/. The stage-3 MOCK uses a master-held
# key (worker plumbing only); THIS uses the genuine sandbox-held key (the real agent).
#
# Prereqs — set up by `bash harness/phase1-wire-demo.sh --real` (run on the operator
# host first): the `agentkeys` binary + the §10.2-paired agent device-session + the
# MCP server, all inside the sandbox. The stage-3 script UPLOADS this file to the
# sandbox automatically (to $HOME/sandbox-agent-isolation.sh); you just run it here.
#
#   bash "$HOME/sandbox-agent-isolation.sh" [namespace]
set -uo pipefail

NS="${1:-${MEMORY_NS:-travel}}"
AGENT_BIN="${AGENT_BIN:-$(command -v agentkeys 2>/dev/null || echo "$HOME/.local/bin/agentkeys")}"
[ -x "$AGENT_BIN" ] || { echo "FAIL: no agentkeys binary in the sandbox ($AGENT_BIN) — run 'phase1-wire-demo.sh --real' on the operator host first." >&2; exit 1; }

content="sandbox-isolation-proof-$$-$(date +%s 2>/dev/null || echo n)"
echo "== §10.2 agent isolation — the agent signs with its SANDBOX-held key (not the master) ==" >&2

# POSITIVE: the agent stores + reads back its OWN memory namespace. This is the real
# cap-mint → STS-signed-as-the-agent → worker → S3 path; success proves the
# sandbox-resident key is a valid, scoped actor.
if ! "$AGENT_BIN" memory put --namespace "$NS" --content "$content" >&2; then
  echo "FAIL: agent memory put (own prefix) — check the in-sandbox MCP server + broker/worker reachability." >&2
  exit 1
fi
got="$("$AGENT_BIN" hook memory-inject --namespaces "$NS" </dev/null 2>/dev/null || true)"
if printf '%s' "$got" | grep -q "$content"; then
  echo "OK: agent stored + read memory:$NS in ITS OWN prefix — real §10.2 agent, key never left the sandbox." >&2
else
  echo "FAIL: agent could not read back the memory:$NS it just wrote." >&2
  exit 1
fi

# NOTE on cross-actor isolation: the agent's STS creds are tagged with ITS actor_omni,
# so the worker physically scopes it to bots/<agent_omni>/ — the cross-actor DENIAL is
# enforced at the IAM layer and is already proven by stage-3 steps 4-9. The agent CLI
# has no way to target another actor's prefix, so this script proves the POSITIVE path
# (the real agent works) — the negative path is the master/mock IAM test in stage 3.
echo "== PASS: tested against the sandbox (the real agent), not the master-held mock. ==" >&2
