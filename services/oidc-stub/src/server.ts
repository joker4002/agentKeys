import express, { type Request, type Response } from "express";
import { SignJWT } from "jose";
import { loadKeypair, type LoadedKeypair } from "./keys.js";

const ISSUER = process.env["OIDC_STUB_ISSUER"] ?? "https://oidc.agentkeys.dev";
const PORT = parseInt(process.env["OIDC_STUB_PORT"] ?? "34568", 10);

export function buildApp(keypair: LoadedKeypair): express.Application {
  const app = express();
  app.use(express.json());

  app.get("/.well-known/openid-configuration", (_req: Request, res: Response) => {
    res.json({
      issuer: ISSUER,
      jwks_uri: `${ISSUER}/.well-known/jwks.json`,
      response_types_supported: ["id_token"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["ES256"],
      scopes_supported: ["openid"],
      token_endpoint_auth_methods_supported: ["none"],
      claims_supported: [
        "iss",
        "sub",
        "aud",
        "iat",
        "exp",
        "nbf",
        "agentkeys_attested_at",
        "agentkeys_enclave_tier",
        "agentkeys_child_wallet",
        "agentkeys_grant_id",
        "agentkeys_operation",
        "agentkeys_user_wallet",
      ],
    });
  });

  app.get("/.well-known/jwks.json", (_req: Request, res: Response) => {
    res.json({
      keys: [keypair.publicJwk],
    });
  });

  app.post("/internal/sign", async (req: Request, res: Response) => {
    const claims = req.body as Record<string, unknown>;
    if (!claims || typeof claims !== "object") {
      res.status(400).json({ error: "Request body must be a JSON object of claims" });
      return;
    }

    const nowSec = Math.floor(Date.now() / 1000);
    const expSec = typeof claims["exp"] === "number" ? claims["exp"] : nowSec + 300;

    const jwtBuilder = new SignJWT({ ...claims })
      .setProtectedHeader({ alg: "ES256", kid: keypair.kid })
      .setIssuedAt(nowSec)
      .setExpirationTime(expSec)
      .setIssuer((claims["iss"] as string | undefined) ?? ISSUER);

    if (claims["sub"] !== undefined) {
      jwtBuilder.setSubject(claims["sub"] as string);
    }
    if (claims["aud"] !== undefined) {
      jwtBuilder.setAudience(claims["aud"] as string | string[]);
    }
    if (claims["nbf"] !== undefined) {
      jwtBuilder.setNotBefore(claims["nbf"] as number);
    }

    const jwt = await jwtBuilder.sign(keypair.privateKey);
    res.json({ jwt });
  });

  return app;
}

async function main(): Promise<void> {
  const keypair = await loadKeypair();
  const app = buildApp(keypair);

  app.listen(PORT, () => {
    console.log(`[oidc-stub] Listening on http://localhost:${PORT}`);
    console.log(`[oidc-stub] Discovery: http://localhost:${PORT}/.well-known/openid-configuration`);
    console.log(`[oidc-stub] JWKS:      http://localhost:${PORT}/.well-known/jwks.json`);
    console.log(`[oidc-stub] Sign:      POST http://localhost:${PORT}/internal/sign`);
    console.log(`[oidc-stub] Issuer:    ${ISSUER}`);
  });
}

main().catch((err) => {
  console.error("[oidc-stub] Fatal startup error:", err);
  process.exit(1);
});
