#!/usr/bin/env bash
# Dump the most recent inbound email from s3://$BUCKET/inbound/ so you can
# see the actual From / Subject / Body without guessing. Applies the SAME
# quoted-printable normalization that ses-s3.ts does, so the URLs you see
# here are exactly what the scraper sees.
#
#   source scripts/stage6-demo-env.sh
#   ./scripts/stage6-inspect-email.sh                 # latest email
#   ./scripts/stage6-inspect-email.sh <key>           # specific key
#   ./scripts/stage6-inspect-email.sh --all           # list keys + headers

set -euo pipefail

: "${AGENTKEYS_SES_BUCKET:?env not loaded — run 'source scripts/stage6-demo-env.sh' first}"
: "${AWS_ACCESS_KEY_ID:?env not loaded — run 'source scripts/stage6-demo-env.sh' first}"

BUCKET="$AGENTKEYS_SES_BUCKET"

# Mirror ses-s3.ts normalizeQuotedPrintable(): strip QP soft-wraps then
# decode the common reserved chars that split URLs.
normalize_qp() {
  # 1. Strip CRs (SES mails use CRLF; makes later regexes sane)
  # 2. Strip QP soft-wrap sequence "=\n"
  # 3. Decode =3D =2E =2F =3A =3F =26 to = . / : ? &
  tr -d '\r' | perl -0777 -pe 's/=\n//g; s/=3D/=/gi; s/=2E/./gi; s/=2F/\//gi; s/=3A/:/gi; s/=3F/?/gi; s/=26/&/gi'
}

if [[ "${1:-}" == "--all" ]]; then
  echo "=== All inbound/* keys with From+Subject headers ==="
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix inbound/ \
    --query "sort_by(Contents,&LastModified)[*].[Key,LastModified]" \
    --output text | while read -r key ts; do
    [[ "$key" == "inbound/AMAZON_SES_SETUP_NOTIFICATION" ]] && continue
    headers=$(aws s3 cp "s3://$BUCKET/$key" - 2>/dev/null | tr -d '\r' | head -40 | grep -iE '^(From|Subject):' | head -2)
    echo "--- $key ($ts) ---"
    echo "$headers"
  done
  exit 0
fi

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
  KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix inbound/ \
    --query "sort_by(Contents[?Key!=\`inbound/AMAZON_SES_SETUP_NOTIFICATION\`], &LastModified)[-1].Key" \
    --output text)
  [[ "$KEY" == "None" || -z "$KEY" ]] && { echo "No inbound emails found."; exit 1; }
  echo "Latest: $KEY"
fi

RAW="/tmp/stage6-email-${KEY##*/}.eml"
NORM="/tmp/stage6-email-${KEY##*/}.normalized.txt"
aws s3 cp "s3://$BUCKET/$KEY" "$RAW" >/dev/null
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
