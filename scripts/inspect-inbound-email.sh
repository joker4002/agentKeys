#!/usr/bin/env bash
# Dump the most recent inbound email from s3://$BUCKET/inbound/ so you
# can see the actual From / Subject / Body without guessing. Applies the
# SAME quoted-printable normalization that provisioner-scripts/email-backends/
# ses-s3.ts does, so the URLs you see here are exactly what the scraper sees.
#
# Stage 7 replacement for scripts/archived/stage6-inspect-email.sh.
# Reads $BUCKET from your workstation env (operator-workstation.env or any
# other source) — does NOT depend on the dropped Stage 6
# AGENTKEYS_SES_BUCKET / DAEMON_ACCESS_KEY_ID env wiring.
#
#   awsp agentkeys-admin
#   set -a; source scripts/operator-workstation.env; set +a
#   ./scripts/inspect-inbound-email.sh                 # latest email
#   ./scripts/inspect-inbound-email.sh <key>           # specific key
#   ./scripts/inspect-inbound-email.sh --all           # list keys + headers

set -euo pipefail

: "${BUCKET:?BUCKET is empty. Run 'set -a; source scripts/operator-workstation.env; set +a' first.}"
: "${REGION:?REGION is empty. Run 'set -a; source scripts/operator-workstation.env; set +a' first. (agentkeys-admin profile defaults to us-west-2; the bucket lives in us-east-1.)}"

# Mirror provisioner-scripts/email-backends/ses-s3.ts normalizeQuotedPrintable():
# strip QP soft-wraps then decode the common reserved chars that split URLs.
normalize_qp() {
  # 1. Strip CRs (SES mails use CRLF; makes later regexes sane)
  # 2. Strip QP soft-wrap sequence "=\n"
  # 3. Decode =3D =2E =2F =3A =3F =26 to = . / : ? &
  tr -d '\r' | perl -0777 -pe 's/=\n//g; s/=3D/=/gi; s/=2E/./gi; s/=2F/\//gi; s/=3A/:/gi; s/=3F/?/gi; s/=26/&/gi'
}

if [[ "${1:-}" == "--all" ]]; then
  echo "=== All inbound/* keys with From+Subject headers ==="
  aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix inbound/ \
    --query "sort_by(Contents,&LastModified)[*].[Key,LastModified]" \
    --output text | while read -r key ts; do
    [[ "$key" == "inbound/AMAZON_SES_SETUP_NOTIFICATION" ]] && continue
    headers=$(aws s3 --region "$REGION" cp "s3://$BUCKET/$key" - 2>/dev/null | tr -d '\r' | head -40 | grep -iE '^(From|Subject):' | head -2)
    echo "--- $key ($ts) ---"
    echo "$headers"
  done
  exit 0
fi

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
  KEY=$(aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix inbound/ \
    --query "sort_by(Contents[?Key!=\`inbound/AMAZON_SES_SETUP_NOTIFICATION\`], &LastModified)[-1].Key" \
    --output text)
  [[ "$KEY" == "None" || -z "$KEY" ]] && { echo "No inbound emails found."; exit 1; }
  echo "Latest: $KEY"
fi

RAW="/tmp/inbound-email-${KEY##*/}.eml"
NORM="/tmp/inbound-email-${KEY##*/}.normalized.txt"
aws s3 --region "$REGION" cp "s3://$BUCKET/$KEY" "$RAW" >/dev/null
cat "$RAW" | normalize_qp > "$NORM"
echo "Saved raw: $RAW"
echo "Saved normalized (what scraper sees): $NORM"
echo ""

echo "=== Headers (normalized) ==="
head -40 "$NORM" | grep -iE '^(From|To|Subject|Content-Type|Content-Transfer-Encoding):' || true
echo ""

echo "=== Body after first blank line, first 120 lines (normalized) ==="
awk 'BEGIN{b=0} b{print} /^$/{b=1}' "$NORM" | head -120
echo ""

echo "=== All hrefs (normalized) ==="
grep -oE 'href="[^"]+"' "$NORM" | head -10 || echo "(none)"
echo ""

echo "=== All https:// URLs (normalized, deduped) ==="
grep -oE 'https://[^ \t\n<>"'"'"']*' "$NORM" | sort -u | head -20 || echo "(none)"
echo ""

echo "=== URLs that would match scraper's codeRegex ==="
grep -oE 'https://[^ \t\n<>"'"'"']*(clerk|/verify|ticket=|verification)[^ \t\n<>"'"'"']*' "$NORM" | sort -u | head -10 || echo "(NONE — regex would miss this email!)"
