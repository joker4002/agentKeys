import { generateKeyPair, exportJWK, importJWK, type KeyLike, type JWK } from "jose";
import { readFile, writeFile, mkdir, chmod } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const KEYPAIR_DIR = join(homedir(), ".agentkeys", "oidc-stub");
const KEYPAIR_PATH = join(KEYPAIR_DIR, "keypair.json");

export interface LoadedKeypair {
  privateKey: KeyLike;
  publicKey: KeyLike;
  publicJwk: JWK;
  kid: string;
}

interface PersistedKeypair {
  kid: string;
  privateJwk: JWK;
  publicJwk: JWK;
}

async function generateAndPersistKeypair(): Promise<LoadedKeypair> {
  const { privateKey, publicKey } = await generateKeyPair("ES256", {
    extractable: true,
  });

  const privateJwk = await exportJWK(privateKey);
  const publicJwk = await exportJWK(publicKey);
  const kid = `v1-${Date.now()}`;
  privateJwk.kid = kid;
  publicJwk.kid = kid;
  publicJwk.alg = "ES256";
  publicJwk.use = "sig";

  const persisted: PersistedKeypair = { kid, privateJwk, publicJwk };

  await mkdir(KEYPAIR_DIR, { recursive: true });
  await writeFile(KEYPAIR_PATH, JSON.stringify(persisted, null, 2), {
    mode: 0o600,
  });
  await chmod(KEYPAIR_PATH, 0o600);

  console.log(`[oidc-stub] Generated new ES256 keypair (kid=${kid}), cached at ${KEYPAIR_PATH}`);

  return {
    privateKey,
    publicKey,
    publicJwk,
    kid,
  };
}

async function loadPersistedKeypair(): Promise<LoadedKeypair> {
  const raw = await readFile(KEYPAIR_PATH, "utf-8");
  const persisted: PersistedKeypair = JSON.parse(raw);

  const privateKey = (await importJWK(persisted.privateJwk, "ES256")) as KeyLike;
  const publicKey = (await importJWK(persisted.publicJwk, "ES256")) as KeyLike;

  console.log(`[oidc-stub] Loaded persisted ES256 keypair (kid=${persisted.kid}) from ${KEYPAIR_PATH}`);

  return {
    privateKey,
    publicKey,
    publicJwk: persisted.publicJwk,
    kid: persisted.kid,
  };
}

/**
 * Load the ES256 keypair for this stub instance.
 *
 * Dev path: generates a fresh P-256 keypair at startup, caches it to
 * ~/.agentkeys/oidc-stub/keypair.json (mode 0600) for persistence across restarts.
 *
 * Prod placeholder (TODO): when AGENTKEYS_OIDC_KMS_KEY_ID is set, delegate signing
 * to AWS KMS using the AsymmetricSign API. See the TODO block below. This stub
 * intentionally does NOT implement KMS signing — the TEE-derived key path
 * (oidc/issuer/v1) described in wiki/oidc-federation.md §Architecture replaces
 * both this dev keypair and the KMS placeholder in Stage 6 production.
 *
 * SECURITY NOTICE: See README.md — this is a TEE-INTERIM STUB only.
 */
export async function loadKeypair(): Promise<LoadedKeypair> {
  const kmsKeyId = process.env["AGENTKEYS_OIDC_KMS_KEY_ID"];
  if (kmsKeyId) {
    // TODO: Production Stage 6 — use AWS KMS AsymmetricSign with the key referenced
    // by AGENTKEYS_OIDC_KMS_KEY_ID. The KMS key must be an ECC_NIST_P256 key with
    // SIGN_VERIFY usage. Signing via KMS: call kms.sign({ KeyId, Message, MessageType,
    // SigningAlgorithm: "ECDSA_SHA_256" }) and assemble the JWT manually. Public key
    // can be fetched once via kms.getPublicKey({ KeyId }) and cached.
    //
    // IMPORTANT: Production Stage 6 replaces this entire stub with a TEE-derived
    // oidc/issuer/v1 key per wiki/oidc-federation.md §Architecture. Do NOT treat
    // KMS as the final architecture — it is only a stepping stone.
    throw new Error(
      `[oidc-stub] AGENTKEYS_OIDC_KMS_KEY_ID is set (${kmsKeyId}) but KMS signing is not ` +
        `implemented in this stub. This path is reserved for the production Stage 6 TEE signer. ` +
        `Unset the env var to use the local dev keypair.`
    );
  }

  if (existsSync(KEYPAIR_PATH)) {
    return loadPersistedKeypair();
  }
  return generateAndPersistKeypair();
}
