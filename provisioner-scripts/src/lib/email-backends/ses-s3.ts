import type { FetchOpts } from "../email.js";
import { S3Client, ListObjectsV2Command, GetObjectCommand } from "@aws-sdk/client-s3";

interface EmailTimeoutError {
  code: "EMAIL_TIMEOUT";
  elapsed_ms: number;
}

function parseEmailHeaders(rawMime: string): { from: string; subject: string; body: string } {
  const lines = rawMime.split(/\r?\n/);
  let from = "";
  let subject = "";
  let bodyStartIndex = -1;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line === "") {
      bodyStartIndex = i + 1;
      break;
    }
    const lower = line.toLowerCase();
    if (lower.startsWith("from:")) {
      from = line.slice(5).trim();
    } else if (lower.startsWith("subject:")) {
      subject = line.slice(8).trim();
    }
  }

  const body = bodyStartIndex >= 0 ? lines.slice(bodyStartIndex).join("\n") : "";
  return { from, subject, body };
}

async function streamToString(stream: NodeJS.ReadableStream): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string));
  }
  return Buffer.concat(chunks).toString("utf-8");
}

export async function fetchViaSesS3(opts: FetchOpts, s3ClientOverride?: S3Client): Promise<string> {
  const bucket = process.env["AGENTKEYS_SES_BUCKET"];
  if (!bucket) {
    throw new Error("AGENTKEYS_SES_BUCKET env var is required for ses-s3 backend");
  }

  const s3 = s3ClientOverride ?? new S3Client({});

  const pollIntervalMs = opts.pollIntervalMs ?? 2000;
  const startedAt = Date.now();
  const seenKeys = new Set<string>();

  while (true) {
    const elapsed = Date.now() - startedAt;

    if (elapsed >= opts.timeoutMs) {
      const timeoutErr: EmailTimeoutError = { code: "EMAIL_TIMEOUT", elapsed_ms: elapsed };
      throw timeoutErr;
    }

    const listResponse = await s3.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: "inbound/" })
    );

    const objects = listResponse.Contents ?? [];

    for (const obj of objects) {
      const key = obj.Key;
      if (!key || seenKeys.has(key)) continue;
      seenKeys.add(key);

      const getResponse = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
      if (!getResponse.Body) continue;

      const rawMime = await streamToString(getResponse.Body as NodeJS.ReadableStream);
      const { from, subject, body } = parseEmailHeaders(rawMime);

      if (!opts.from.test(from) || !opts.subject.test(subject)) {
        continue;
      }

      const match = opts.codeRegex.exec(body);
      if (match && match[1] !== undefined) {
        return match[1];
      }
    }

    const remainingMs = opts.timeoutMs - (Date.now() - startedAt);
    if (remainingMs <= 0) {
      const timeoutErr: EmailTimeoutError = { code: "EMAIL_TIMEOUT", elapsed_ms: Date.now() - startedAt };
      throw timeoutErr;
    }

    await new Promise<void>((resolve) =>
      setTimeout(resolve, Math.min(pollIntervalMs, remainingMs))
    );
  }
}
