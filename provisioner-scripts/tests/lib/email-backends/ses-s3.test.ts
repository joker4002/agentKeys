import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import { fetchViaSesS3 } from "../../../src/lib/email-backends/ses-s3.js";
import { S3Client } from "@aws-sdk/client-s3";

function makeMockS3(emlContents: string[]): S3Client {
  const s3 = new S3Client({ region: "us-east-1" });

  const objects = emlContents.map((_, i) => ({ Key: `inbound/msg-${i}.eml` }));

  vi.spyOn(s3, "send").mockImplementation(async (command: unknown) => {
    const cmd = command as { constructor: { name: string } };
    if (cmd.constructor.name === "ListObjectsV2Command") {
      return { Contents: objects };
    }
    if (cmd.constructor.name === "GetObjectCommand") {
      const getCmd = command as { input: { Key: string } };
      const idx = objects.findIndex((o) => o.Key === getCmd.input.Key);
      if (idx === -1 || !emlContents[idx]) return { Body: null };
      const content = emlContents[idx];
      const readable = new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(content));
          controller.close();
        },
      }) as unknown as NodeJS.ReadableStream;
      return { Body: readable };
    }
    return {};
  });

  return s3;
}

function buildEml(from: string, subject: string, body: string): string {
  return [
    `From: ${from}`,
    `Subject: ${subject}`,
    `Content-Type: text/plain`,
    ``,
    body,
  ].join("\r\n");
}

describe("ses-s3 backend", () => {
  beforeEach(() => {
    process.env["AGENTKEYS_SES_BUCKET"] = "test-ses-bucket";
  });

  afterEach(() => {
    delete process.env["AGENTKEYS_SES_BUCKET"];
    vi.restoreAllMocks();
  });

  it("extracts code from a matching .eml object", async () => {
    const eml = buildEml(
      "noreply@example.com",
      "Your verification code",
      "Your code is 789012. Do not share."
    );
    const s3 = makeMockS3([eml]);

    const code = await fetchViaSesS3(
      {
        from: /noreply@example\.com/,
        subject: /verification code/i,
        codeRegex: /(\d{6})/,
        timeoutMs: 5000,
      },
      s3
    );

    expect(code).toBe("789012");
  });

  it("skips objects with non-matching from header", async () => {
    const eml = buildEml(
      "spam@wrong.com",
      "Your verification code",
      "Code: 111111"
    );
    const s3 = makeMockS3([eml]);

    await expect(
      fetchViaSesS3(
        {
          from: /noreply@example\.com/,
          subject: /verification code/i,
          codeRegex: /(\d{6})/,
          timeoutMs: 80,
          pollIntervalMs: 20,
        },
        s3
      )
    ).rejects.toMatchObject({ code: "EMAIL_TIMEOUT" });
  });

  it("skips objects with non-matching subject header", async () => {
    const eml = buildEml(
      "noreply@example.com",
      "Newsletter",
      "Code: 222222"
    );
    const s3 = makeMockS3([eml]);

    await expect(
      fetchViaSesS3(
        {
          from: /noreply@example\.com/,
          subject: /verification code/i,
          codeRegex: /(\d{6})/,
          timeoutMs: 80,
          pollIntervalMs: 20,
        },
        s3
      )
    ).rejects.toMatchObject({ code: "EMAIL_TIMEOUT" });
  });

  it("times out when bucket is empty", async () => {
    const s3 = new S3Client({ region: "us-east-1" });
    vi.spyOn(s3, "send").mockResolvedValue({ Contents: [] } as never);

    await expect(
      fetchViaSesS3(
        {
          from: /noreply@example\.com/,
          subject: /verification code/i,
          codeRegex: /(\d{6})/,
          timeoutMs: 80,
          pollIntervalMs: 20,
        },
        s3
      )
    ).rejects.toMatchObject({ code: "EMAIL_TIMEOUT" });
  });

  it("throws clear error when AGENTKEYS_SES_BUCKET is missing", async () => {
    delete process.env["AGENTKEYS_SES_BUCKET"];
    const s3 = new S3Client({ region: "us-east-1" });

    await expect(
      fetchViaSesS3(
        {
          from: /./,
          subject: /./,
          codeRegex: /(\d{6})/,
          timeoutMs: 5000,
        },
        s3
      )
    ).rejects.toThrow("AGENTKEYS_SES_BUCKET");
  });

  it("handles multiple objects and returns first code match", async () => {
    const emls = [
      buildEml("spam@wrong.com", "Promo", "nothing here"),
      buildEml("noreply@example.com", "Your verification code", "Code: 345678"),
    ];
    const s3 = makeMockS3(emls);

    const code = await fetchViaSesS3(
      {
        from: /noreply@example\.com/,
        subject: /verification code/i,
        codeRegex: /(\d{6})/,
        timeoutMs: 5000,
      },
      s3
    );

    expect(code).toBe("345678");
  });
});
