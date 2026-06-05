#!/usr/bin/env bash
# scripts/heima-fund-master.sh — point-1 subsidy (issue #196). Fund the master's
# on-chain gas-paying wallet (the msg.sender of the register-master tx) from the
# deployer so `heima-register-first-master.sh` / the daemon ui-bridge register
# shell-out has gas. ~0.2 HEI by default.
#
# DELIBERATELY local + operator-run + one-time — NOT a broker endpoint and NOT
# auto-on-login. Broker auto-funding every login would be a Sybil drain on the
# deployer (issue #196 "Point-1 subsidy"). The operator runs this once.
#
# Idempotent: delegates the transfer to scripts/heima-fund-account.sh, which
# skips when the recipient already holds >= --amount-hei. A second run is a
# no-op skip.
#
# Under issue #196 option (α) the register tx is signed by the deployer key
# itself (operator == deployer in the CLI/harness path), so the default target
# IS the deployer and this script is a clean no-op skip there. It exists so the
# operator has a single "fund my master" command and so that when the signer
# shifts to a distinct master wallet (β/γ), the same command funds the right
# account. Pass --to to fund an explicit master/session wallet.
#
# Usage:
#   bash scripts/heima-fund-master.sh [--amount-hei 0.2] [--to 0x<master>] [--dry-run]
#
# Env (same deployer resolution as heima-fund-account.sh / heima-bring-up.sh):
#   HEIMA_DEPLOYER_KEY=0x...              (raw 0x-prefixed private key), or
#   HEIMA_DEPLOYER_MNEMONIC_FILE=<path>   (default: ./test-hei in repo root), or
#   ~/.agentkeys/<chain>-deployer.key     (persisted cache)
#   AGENTKEYS_CHAIN                        (default heima)

set -euo pipefail

AMOUNT_HEI="0.2"
TO_ADDR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --amount-hei)   [ $# -lt 2 ] && { echo "--amount-hei requires a value" >&2; exit 1; }; AMOUNT_HEI="$2"; shift 2 ;;
    --amount-hei=*) AMOUNT_HEI="${1#*=}"; shift ;;
    --to)           [ $# -lt 2 ] && { echo "--to requires a value" >&2; exit 1; }; TO_ADDR="$2"; shift 2 ;;
    --to=*)         TO_ADDR="${1#*=}"; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"

# Resolve the master gas-payer address (the register tx msg.sender). Default to
# the deployer address — the same 3-way resolution heima-fund-account.sh uses —
# unless --to overrides it. We only need the ADDRESS here; heima-fund-account.sh
# resolves the deployer KEY again to actually sign the transfer.
if [ -z "$TO_ADDR" ]; then
  DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key}"
  HEIMA_DEPLOYER_MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
  if [ -n "${HEIMA_DEPLOYER_KEY:-}" ]; then
    TO_ADDR=$(cast wallet address --private-key "$HEIMA_DEPLOYER_KEY") || die "bad HEIMA_DEPLOYER_KEY"
  elif [ -f "$HEIMA_DEPLOYER_MNEMONIC_FILE" ]; then
    if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
      log "Installing scripts/node_modules deps (first run only)…"
      npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install failed"
    fi
    TO_ADDR=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$HEIMA_DEPLOYER_MNEMONIC_FILE" | jq -r .address) \
      || die "deriving deployer address from $HEIMA_DEPLOYER_MNEMONIC_FILE failed"
  elif [ -f "$DEPLOYER_KEY_FILE" ]; then
    TO_ADDR=$(cast wallet address --private-key "$(cat "$DEPLOYER_KEY_FILE")" 2>/dev/null) \
      || die "$DEPLOYER_KEY_FILE is corrupt"
  else
    die "no deployer key found (set HEIMA_DEPLOYER_KEY, $HEIMA_DEPLOYER_MNEMONIC_FILE, or $DEPLOYER_KEY_FILE) — or pass --to 0x<master>"
  fi
  log "master gas-payer defaults to deployer address $TO_ADDR (issue #196 option α: operator == deployer)"
fi

FUND_ARGS=(--to "$TO_ADDR" --amount-hei "$AMOUNT_HEI")
[ "$DRY_RUN" = "1" ] && FUND_ARGS+=(--dry-run)

log "Funding master gas-payer $TO_ADDR with ≥ $AMOUNT_HEI HEI (idempotent skip-if-funded) …"
exec bash "$REPO_ROOT/scripts/heima-fund-account.sh" "${FUND_ARGS[@]}"
