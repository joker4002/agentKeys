import { describe, it, expect, beforeAll } from "vitest";
import { generateKeyPair, exportJWK, jwtVerify, createRemoteJWKSet, importJWK, type KeyLike, type JWK } from "jose";
import express from "express";
import type { Server } from "node:http";
import { buildApp } from "../src/server.js";
import type { LoadedKeypair } from "../src/keys.js";

let server: Server;
let baseUrl: string;
let keypair: LoadedKeypair;

beforeAll(async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = "test-v1";
  publicJwk.alg = "ES256";
  publicJwk.use = "sig";

  keypair = {
    privateKey: privateKey as KeyLike,
    publicKey: publicKey as KeyLike,
    publicJwk,
    kid: "test-v1",
  };

  const app = buildApp(keypair);

  await new Promise<void>((resolve) => {
    server = app.listen(0, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      baseUrl = `http://localhost:${port}`;
      resolve();
    });
  });

  return () => {
    server.close();
  };
});

describe("GET /.well-known/openid-configuration", () => {
  it("returns 200 with valid JSON", async () => {
    const response = await fetch(`${baseUrl}/.well-known/openid-configuration`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/application\/json/);
  });

  it("contains all required OIDC fields", async () => {
    const response = await fetch(`${baseUrl}/.well-known/openid-configuration`);
    const doc = (await response.json()) as Record<string, unknown>;

    expect(typeof doc["issuer"]).toBe("string");
    expect(typeof doc["jwks_uri"]).toBe("string");
    expect(doc["id_token_signing_alg_values_supported"]).toEqual(["ES256"]);
    expect(doc["response_types_supported"]).toContain("id_token");
    expect(doc["subject_types_supported"]).toContain("public");
  });

  it("jwks_uri points to the jwks endpoint", async () => {
    const response = await fetch(`${baseUrl}/.well-known/openid-configuration`);
    const doc = (await response.json()) as Record<string, unknown>;

    expect(typeof doc["jwks_uri"]).toBe("string");
    expect((doc["jwks_uri"] as string).endsWith("/.well-known/jwks.json")).toBe(true);
  });
});

describe("GET /.well-known/jwks.json", () => {
  it("returns 200 with valid JSON", async () => {
    const response = await fetch(`${baseUrl}/.well-known/jwks.json`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/application\/json/);
  });

  it("contains exactly one ES256 JWK", async () => {
    const response = await fetch(`${baseUrl}/.well-known/jwks.json`);
    const jwks = (await response.json()) as Record<string, unknown>;

    expect(Array.isArray(jwks["keys"])).toBe(true);
    const keys = jwks["keys"] as Record<string, unknown>[];
    expect(keys).toHaveLength(1);

    const key = keys[0];
    expect(key["kty"]).toBe("EC");
    expect(key["crv"]).toBe("P-256");
    expect(key["alg"]).toBe("ES256");
    expect(key["use"]).toBe("sig");
    expect(typeof key["x"]).toBe("string");
    expect(typeof key["y"]).toBe("string");
    expect(key["d"]).toBeUndefined();
  });
});

describe("POST /internal/sign", () => {
  it("returns 400 when body is missing", async () => {
    const response = await fetch(`${baseUrl}/internal/sign`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "null",
    });
    expect(response.status).toBe(400);
  });

  it("produces a JWT that verifies against the JWKS endpoint", async () => {
    const claims = {
      sub: "enclave:mrenclave123:mrsigner456:agent:0xabc",
      aud: "sts.amazonaws.com",
      agentkeys_operation: "ses.send",
      agentkeys_enclave_tier: "dev",
    };

    const signResponse = await fetch(`${baseUrl}/internal/sign`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(claims),
    });
    expect(signResponse.status).toBe(200);

    const body = (await signResponse.json()) as { jwt: string };
    expect(typeof body["jwt"]).toBe("string");

    const jwksUri = new URL(`${baseUrl}/.well-known/jwks.json`);
    const remoteJwks = createRemoteJWKSet(jwksUri);

    const { payload } = await jwtVerify(body.jwt, remoteJwks, {
      audience: "sts.amazonaws.com",
    });

    expect(payload["sub"]).toBe(claims.sub);
    expect(payload["agentkeys_operation"]).toBe("ses.send");
    expect(payload["agentkeys_enclave_tier"]).toBe("dev");
    expect(typeof payload["iat"]).toBe("number");
    expect(typeof payload["exp"]).toBe("number");
  });

  it("JWT header contains alg=ES256 and kid matching the JWKS key", async () => {
    const signResponse = await fetch(`${baseUrl}/internal/sign`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sub: "test-sub", aud: "test-aud" }),
    });
    const { jwt } = (await signResponse.json()) as { jwt: string };

    const headerB64 = jwt.split(".")[0];
    const headerJson = Buffer.from(headerB64, "base64url").toString("utf-8");
    const header = JSON.parse(headerJson) as Record<string, unknown>;

    expect(header["alg"]).toBe("ES256");
    expect(header["kid"]).toBe("test-v1");
  });

  it("JWT verifies against the public key from JWKS by importing directly", async () => {
    const signResponse = await fetch(`${baseUrl}/internal/sign`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sub: "direct-verify-sub", aud: "sts.amazonaws.com" }),
    });
    const { jwt } = (await signResponse.json()) as { jwt: string };

    const jwksResponse = await fetch(`${baseUrl}/.well-known/jwks.json`);
    const jwks = (await jwksResponse.json()) as { keys: JWK[] };
    const publicKey = await importJWK(jwks.keys[0]!, "ES256");

    const { payload } = await jwtVerify(jwt, publicKey, {
      audience: "sts.amazonaws.com",
    });
    expect(payload["sub"]).toBe("direct-verify-sub");
  });
});
