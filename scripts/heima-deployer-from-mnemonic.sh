#!/usr/bin/env bash
# Derive the Heima deployer EVM private key from a BIP39 mnemonic and save it
# to the canonical deployer key file that setup-heima.sh reads.
#
# Use this when you ALREADY HAVE a wallet (hardware wallet, MetaMask, prior
# deploy) and want to reuse its mnemonic as the deployer. For a fresh wallet
# generated on this workstation, use `cast wallet new` (see docs/ci-setup.md §2).
#
# Usage:
#   bash scripts/heima-deployer-from-mnemonic.sh             # prod, interactive
#   bash scripts/heima-deployer-from-mnemonic.sh --test      # test, interactive
#   bash scripts/heima-deployer-from-mnemonic.sh --mnemonic-file /path/to/mnemonic.txt
#   AGENTKEYS_DEPLOYER_MNEMONIC="word1 word2 …" bash scripts/heima-deployer-from-mnemonic.sh
#   echo "$MNEMONIC" | bash scripts/heima-deployer-from-mnemonic.sh --stdin
#
# Flags:
#   --test                  derive the TEST deployer (out path gets -test suffix)
#   --prod                  derive the PROD deployer (default)
#   --out <path>            explicit output path (overrides --test/--prod default)
#   --index N               BIP-44 address index (default 0)
#   --path "m/44'/60'/…"    full derivation path (overrides --index)
#   --mnemonic-file <path>  read mnemonic from this file (more secure than CLI)
#   --stdin                 read mnemonic from stdin
#   --help                  print this header
#
# Output path defaults (matches setup-heima.sh's HEIMA_DEPLOYER_KEY_FILE
# resolution: ${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key}):
#   prod  → ~/.agentkeys/${AGENTKEYS_CHAIN:-heima}-deployer.key
#   test  → ~/.agentkeys/${AGENTKEYS_CHAIN:-heima}-deployer-test.key
#
# Idempotent: if the output file exists AND its key already matches the
# derived one, exits 0 with "skip already-matches". If the file exists with
# a DIFFERENT key, fails loud — refuses to overwrite because the existing
# key may be the live deployer for already-deployed contracts (per CLAUDE.md
# idempotent-remote-setup rule: "NEVER overwrite — would invalidate downstream
# encrypted blobs").

set -euo pipefail

STACK="prod"
OUT=""
INDEX="0"
DERIV_PATH=""
MNEMONIC_FILE=""
FROM_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --test)           STACK="test"; shift ;;
    --prod)           STACK="prod"; shift ;;
    --out)            OUT="$2"; shift 2 ;;
    --index)          INDEX="$2"; shift 2 ;;
    --path)           DERIV_PATH="$2"; shift 2 ;;
    --mnemonic-file)  MNEMONIC_FILE="$2"; shift 2 ;;
    --stdin)          FROM_STDIN=1; shift ;;
    -h|--help)        sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

CHAIN="${AGENTKEYS_CHAIN:-heima}"

if [ -z "$OUT" ]; then
  case "$STACK" in
    prod) OUT="$HOME/.agentkeys/${CHAIN}-deployer.key" ;;
    test) OUT="$HOME/.agentkeys/${CHAIN}-deployer-test.key" ;;
  esac
fi

if [ -z "$DERIV_PATH" ]; then
  DERIV_PATH="m/44'/60'/0'/0/${INDEX}"
fi

command -v cast >/dev/null || {
  echo "cast not found — install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
}

# Mnemonic source priority: --mnemonic-file > env var > --stdin > interactive prompt
if [ -n "$MNEMONIC_FILE" ]; then
  [ -f "$MNEMONIC_FILE" ] || { echo "--mnemonic-file: $MNEMONIC_FILE not found" >&2; exit 1; }
  MNEMONIC=$(tr -d '\r\n' < "$MNEMONIC_FILE" | sed 's/^ *//; s/ *$//')
elif [ -n "${AGENTKEYS_DEPLOYER_MNEMONIC:-}" ]; then
  MNEMONIC="$AGENTKEYS_DEPLOYER_MNEMONIC"
elif [ "$FROM_STDIN" = "1" ]; then
  IFS= read -r MNEMONIC
else
  if [ ! -t 0 ]; then
    echo "no mnemonic source (stdin not a terminal; pass --mnemonic-file or --stdin or set AGENTKEYS_DEPLOYER_MNEMONIC)" >&2
    exit 1
  fi
  echo "Paste BIP39 mnemonic (12 or 24 words). Input is hidden — press Enter when done:" >&2
  IFS= read -rs MNEMONIC
  echo >&2
fi

MNEMONIC=$(printf '%s' "$MNEMONIC" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')
[ -n "$MNEMONIC" ] || { echo "mnemonic empty" >&2; exit 1; }

WORD_COUNT=$(printf '%s' "$MNEMONIC" | wc -w | tr -d ' ')
case "$WORD_COUNT" in
  12|15|18|21|24) ;;
  *) echo "mnemonic word count = $WORD_COUNT (expected 12/15/18/21/24)" >&2; exit 1 ;;
esac

PRIV=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-derivation-path "$DERIV_PATH" 2>&1) || {
  echo "cast wallet private-key failed:" >&2
  echo "$PRIV" >&2
  echo "Check the mnemonic words + derivation path ($DERIV_PATH)" >&2
  exit 1
}

if [[ ! "$PRIV" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "derived key not in 0x<64hex> form: ${PRIV:0:8}…" >&2
  exit 1
fi

ADDR=$(cast wallet address "$PRIV")

if [ -f "$OUT" ]; then
  EXISTING=$(tr -d '\r\n[:space:]' < "$OUT")
  if [ "$EXISTING" = "$PRIV" ]; then
    echo "skip already-matches  ($OUT)"
    echo "address: $ADDR"
    exit 0
  fi
  EXIST_ADDR=$(cast wallet address "$EXISTING" 2>/dev/null || echo "<unparseable>")
  cat >&2 <<EOF
fail $OUT already exists with a DIFFERENT key — refusing to overwrite.

  existing address: $EXIST_ADDR
  derived address:  $ADDR

If you intend to replace the deployer wallet (live contracts will be orphaned
under the previous key):

  mv "$OUT" "$OUT.bak.\$(date +%Y%m%d-%H%M%S)"
  bash $0 $*
EOF
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
umask 077
TMP="${OUT}.tmp.$$"
printf '%s\n' "$PRIV" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$OUT"

echo "ok wrote deployer key"
echo "  stack:   $STACK"
echo "  chain:   $CHAIN"
echo "  path:    $DERIV_PATH"
echo "  out:     $OUT"
echo "  address: $ADDR"
echo
echo "Next: setup-heima.sh will pick this up automatically — for test:"
echo "  HEIMA_DEPLOYER_KEY_FILE=$OUT MAINNET_CONFIRM=1 \\"
echo "    bash scripts/setup-heima.sh --from-step 4 --to-step 8"
