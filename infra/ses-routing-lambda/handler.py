# SES routing Lambda — issue #83 follow-up.
#
# Trigger: S3 ObjectCreated:* on s3://$BUCKET/inbound/*
# Job:     If the `To:` local-part matches the provisioner pattern
#          `or-<0x-wallet>-<unix-ts>`, server-side CopyObject the MIME
#          blob to `bots/<wallet>/inbound/<msg>`. Otherwise no-op
#          (AGENTKEYS magic-link auth emails stay in inbound/ for the
#          broker's existing `/v1/auth/email/*` handlers to consume).
#
# Cost / footprint notes:
#   - Reads only the first 8KB of each object via S3 GetObject Range
#     (header parsing). Body never transits Lambda memory.
#   - CopyObject is server-side (no Lambda data-transfer).
#   - Zero state: no DynamoDB, no Secrets Manager, no network egress.
#   - Memory: 128 MB is enough; runtime: python3.13 for small cold-start.
#   - Concurrency cap: deploy.sh sets reserved-concurrency=10 (one per
#     simultaneous operator provision; well under SES inbound throughput).

import email
import logging
import re
from typing import Any, Optional

log = logging.getLogger()
log.setLevel(logging.INFO)

# Lazy import keeps the module importable in environments without boto3
# (local unit tests with mocked S3). Lambda runtime ships boto3, so the
# import inside `_client()` succeeds with zero cold-start overhead.
try:  # pragma: no cover — only the import-error path matters for tests
    from botocore.exceptions import ClientError as _BotoClientError
except ImportError:
    # Stand-in so `except ClientError` is parseable without boto3 installed.
    class _BotoClientError(Exception):
        pass


ClientError = _BotoClientError

# Matches the local-part the provisioner generates:
#   or-0x<40 hex lowercase>-<unix ts>
# Case-insensitive in the regex but we lowercase the wallet for S3 key.
WALLET_LOCAL_PART_RE = re.compile(
    r"^or-(0x[a-f0-9]{40})-\d+$",
    re.IGNORECASE,
)

# Enough bytes to capture To: + From: + Subject: + Date: even with a
# long DKIM-Signature header. Real headers rarely exceed ~4KB.
HEADER_READ_BYTES = 8192

INBOUND_PREFIX = "inbound/"

# `_s3` is lazily initialized via `_client()` so the module is importable
# without boto3 installed. Tests monkey-patch this directly.
_s3 = None  # type: ignore[assignment]


def _client():
    global _s3
    if _s3 is None:
        import boto3  # local import — avoids module-load failure in tests

        _s3 = boto3.client("s3")
    return _s3


def handler(event: "dict[str, Any]", _context: Any) -> "dict[str, int]":
    routed = 0
    skipped = 0
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        outcome = _route_one(bucket, key)
        if outcome == "routed":
            routed += 1
        else:
            skipped += 1
    return {"routed": routed, "skipped": skipped}


def _route_one(bucket: str, key: str) -> str:
    if not key.startswith(INBOUND_PREFIX):
        log.info("skip key=%s reason=not-under-inbound", key)
        return "skipped"

    head_bytes = _read_head(bucket, key)
    if head_bytes is None:
        return "skipped"

    local_part = _extract_to_local_part(head_bytes)
    if local_part is None:
        log.info("skip key=%s reason=no-To-header", key)
        return "skipped"

    m = WALLET_LOCAL_PART_RE.match(local_part)
    if not m:
        log.info(
            "skip key=%s reason=local-part-not-wallet-routed local_part=%s",
            key,
            local_part,
        )
        return "skipped"

    wallet = m.group(1).lower()
    msg_name = key[len(INBOUND_PREFIX):]
    dest_key = f"bots/{wallet}/inbound/{msg_name}"

    try:
        _client().copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": key},
            Key=dest_key,
            MetadataDirective="COPY",
        )
    except ClientError as e:
        log.error(
            "copy-failed key=%s dest=%s wallet=%s err=%s",
            key,
            dest_key,
            wallet,
            e,
        )
        return "skipped"

    log.info("routed key=%s dest=%s wallet=%s", key, dest_key, wallet)
    return "routed"


def _read_head(bucket: str, key: str) -> Optional[bytes]:
    try:
        resp = _client().get_object(
            Bucket=bucket,
            Key=key,
            Range=f"bytes=0-{HEADER_READ_BYTES - 1}",
        )
        return resp["Body"].read()
    except ClientError as e:
        log.error("head-fetch-failed key=%s err=%s", key, e)
        return None


def _extract_to_local_part(head_bytes: bytes) -> Optional[str]:
    # email.message_from_bytes is permissive enough to handle a truncated
    # header block (missing CRLFCRLF terminator). Just grab the To: value.
    msg = email.message_from_bytes(head_bytes)
    to_header = msg.get("To", "") or ""
    if not to_header:
        return None
    # `To:` can be "name <addr@domain>" or bare "addr@domain". Pull the
    # local-part out of whichever form appears.
    angle_match = re.search(r"<([A-Za-z0-9._%+-]+)@", to_header)
    if angle_match:
        return angle_match.group(1).lower()
    bare_match = re.search(r"([A-Za-z0-9._%+-]+)@", to_header)
    if bare_match:
        return bare_match.group(1).lower()
    return None
