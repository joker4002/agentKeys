# SES routing Lambda

Per-recipient routing for the SES inbound bucket — issue #83 follow-up.

## Why this exists

`agentkeys provision <service>` spawns a CDP scraper that needs to read its
service-signup verification email. The OIDC-assumed `agentkeys-data-role`
is intentionally denied read on `s3://$BUCKET/inbound/` (federation-isolation
rule, cloud-setup.md §4.5). Without per-recipient routing, the scraper
cannot fetch its email via the OIDC workflow.

This Lambda copies inbound objects to per-wallet prefixes the data-role
**can** read, based on the recipient local-part. AGENTKEYS magic-link
auth emails (different local-part pattern) stay in `inbound/` for the
broker's existing handlers.

## Trigger / routing rule

- Triggered by S3 `ObjectCreated:*` on `inbound/*`
- Reads first 8KB of the object (header parse only — body never enters
  Lambda memory)
- If `To:` local-part matches `^or-(0x[a-f0-9]{40})-\d+$`, server-side
  `CopyObject` to `bots/<wallet>/inbound/<msg>` (extract wallet from
  capture group 1)
- Otherwise, no-op

## Cost / footprint

- **Memory** 128 MB; **timeout** 10s; **runtime** python3.13.
- **Reserved concurrency** 10 (well above SES inbound throughput in practice).
- **No state** — no DynamoDB, no Secrets Manager, no network egress.
- **No data transfer charges** — `CopyObject` is server-side; we only
  fetch a Range of the source object for header parsing.

Per-invocation cost is dominated by Lambda's 100-ms-billing granularity:
~1.7 µ$/event at 128 MB (≈ $0.000002). Volume floor is the SES inbound
rate, so the total monthly bill stays single-digit cents at any sensible
operator count.

## Deploy

```bash
# === ON OPERATOR WORKSTATION ===
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a
bash infra/ses-routing-lambda/deploy.sh
```

Idempotent: re-running updates the function code + config, refreshes the
inline IAM policy, and replaces the S3 notification configuration.

## Verify

```bash
# tail Lambda logs while you trigger a real inbound email
aws logs tail /aws/lambda/agentkeys-ses-router --follow --region "$REGION"

# trigger via a real provision
bash scripts/agentkeys-provision-demo.sh --session-id alice openrouter

# confirm the routed copy landed
WALLET_A=$(jq -r .agentkeys_user_wallet ~/.agentkeys/alice/session.json 2>/dev/null \
  || jq -r .wallet ~/.agentkeys/alice/session.json)
aws s3 ls "s3://$BUCKET/bots/$WALLET_A/inbound/" --region "$REGION"
```

## Run unit tests (no AWS access needed)

```bash
cd infra/ses-routing-lambda
python3 -m unittest test_handler -v
```

## Rollback

```bash
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" \
  --notification-configuration '{}'
aws lambda delete-function --function-name agentkeys-ses-router --region "$REGION"
aws iam delete-role-policy --role-name agentkeys-ses-router-lambda-role \
  --policy-name agentkeys-ses-router-lambda-role-inline
aws iam delete-role --role-name agentkeys-ses-router-lambda-role
```

Operators fall back to admin-profile `inspect-inbound-email.sh` to pull
verification URLs manually until the Lambda is redeployed.
