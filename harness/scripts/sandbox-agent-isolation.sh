#!/usr/bin/env bash
# harness/scripts/sandbox-agent-isolation.sh — RUN THIS INSIDE THE AGENT SANDBOX.
#
# The REAL §10.2 agent proof that stage-3 step 11/12 cannot do from the master: the
# agent's OWN binary, signing with the device key that LIVES IN THE SANDBOX (never
# on the master), does live memory + credential roundtrips — cap-mint → STS
# (SIWE as the AGENT) → worker → S3 bots/<agent_omni>/{memory,credentials}/. The
# stage-3 MOCK uses a master-held key (worker plumbing only); THIS uses the
# genuine sandbox-held key (the real agent).
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
cred_service="${SANDBOX_CRED_SERVICE:-sandbox-isolation-proof}"
cred_secret="sandbox-cred-proof-$$-$(date +%s 2>/dev/null || echo n)"
echo "== §10.2 agent isolation — the agent signs with its SANDBOX-held key (not the master) ==" >&2

agent_session_file=""
if [ -n "${SANDBOX_AGENT_SESSION_FILE:-}" ] && [ -r "$SANDBOX_AGENT_SESSION_FILE" ]; then
  agent_session_file="$SANDBOX_AGENT_SESSION_FILE"
elif [ -n "${AGENTKEYS_ACTOR_OMNI:-}" ]; then
  actor_no0x="${AGENTKEYS_ACTOR_OMNI#0x}"
  for candidate in "$HOME/.agentkeys/agent-session-$actor_no0x.jwt" "$HOME/.agentkeys/agent-session-$AGENTKEYS_ACTOR_OMNI.jwt"; do
    if [ -r "$candidate" ]; then
      agent_session_file="$candidate"
      break
    fi
  done
fi

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

# POSITIVE: the same sandbox-held agent identity stores + fetches an OWN
# credential through the credentials worker. The service name is deliberately a
# synthetic proof key so this never overwrites a real provider credential.
if [ -z "$agent_session_file" ]; then
  set -- "$HOME"/.agentkeys/agent-session-*.jwt
  if [ "$#" -eq 1 ] && [ -r "$1" ]; then
    agent_session_file="$1"
  fi
fi
if [ -z "$agent_session_file" ]; then
  echo "FAIL: no sandbox agent session bearer file found for self-owned cred cap-mint. Expected ~/.agentkeys/agent-session-<actor>.jwt or SANDBOX_AGENT_SESSION_FILE." >&2
  exit 1
fi
AGENTKEYS_SESSION_BEARER="$(tr -d '\r\n' < "$agent_session_file")"
export AGENTKEYS_SESSION_BEARER
if ! "$AGENT_BIN" cred store --service "$cred_service" --content "$cred_secret" >&2; then
  echo "FAIL: agent cred store (own prefix) — check in-sandbox MCP + broker/cred-worker/vault-role reachability." >&2
  exit 1
fi
got_cred="$("$AGENT_BIN" cred fetch --service "$cred_service" 2>/dev/null || true)"
if [ "$got_cred" = "$cred_secret" ]; then
  echo "OK: agent stored + fetched credential:$cred_service in ITS OWN prefix — real §10.2 agent, key never left the sandbox." >&2
else
  echo "FAIL: agent could not fetch back the credential:$cred_service it just wrote." >&2
  exit 1
fi

# NOTE on cross-actor isolation: the agent's STS creds are tagged with ITS actor_omni,
# so the worker physically scopes it to bots/<agent_omni>/ — the cross-actor DENIAL is
# enforced at the IAM layer and is already proven by stage-3 steps 4-9. The agent CLI
# has no way to target another actor's prefix, so this script proves the POSITIVE path
# (the real agent works) — the negative path is the master/mock IAM test in stage 3.
echo "== PASS: tested against the sandbox (the real agent), not the master-held mock. ==" >&2
