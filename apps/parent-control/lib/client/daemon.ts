import type {
  AgentKeysClient,
  AnchorStatus,
  CapToken,
  ConnectionStatus,
  DisconnectedStatus,
  K11EnrollBegin,
  K11EnrollFinishInput,
  K11EnrollResult,
  Result,
  RevokeIntent,
} from './types';
import type { Actor, AuditEvent, Namespace, ScopeBits, Worker } from '@/app/_components/types';

/**
 * DaemonBackend — talks to a running agentkeys-daemon over HTTP.
 *
 * PR-B wires K11 enrollment (POST /v1/k11/enroll/begin + .../finish).
 * Every other method still returns the disconnected variant until
 * PR-C lands the read endpoints (/v1/actors, /v1/audit/stream, etc.).
 */
const NOT_YET_WIRED: DisconnectedStatus = {
  kind: 'disconnected',
  reason: 'no-backend-configured',
  detail: 'Endpoint not yet implemented in DaemonBackend (lands in PR-C).',
};

function notWired<T>(): Result<T> {
  return { ok: false, status: NOT_YET_WIRED };
}

function unreachable(detail: string): DisconnectedStatus {
  return { kind: 'disconnected', reason: 'unreachable', detail };
}

const DEFAULT_BASE_URL = 'http://localhost:3114';

export class DaemonBackend implements AgentKeysClient {
  private baseUrl: string;

  constructor(baseUrl?: string) {
    this.baseUrl = (baseUrl ?? process.env.NEXT_PUBLIC_AGENTKEYS_DAEMON_URL ?? DEFAULT_BASE_URL).replace(/\/$/, '');
  }

  async status(): Promise<ConnectionStatus> {
    try {
      const resp = await fetch(`${this.baseUrl}/healthz`, { method: 'GET', cache: 'no-store' });
      if (!resp.ok) {
        return unreachable(`/healthz returned ${resp.status}`);
      }
      return { kind: 'connected', via: 'daemon', endpoint: this.baseUrl };
    } catch (e) {
      return unreachable(`fetch ${this.baseUrl}/healthz failed: ${(e as Error).message}`);
    }
  }

  async listActors(): Promise<Result<Actor[]>> {
    return notWired();
  }

  async getActor(): Promise<Result<Actor | null>> {
    return notWired();
  }

  async listCapTokens(_actorId: string): Promise<Result<CapToken[]>> {
    return notWired();
  }

  async listRecentAuditEvents(): Promise<Result<AuditEvent[]>> {
    return notWired();
  }

  streamAudit(
    _onEvent: (e: AuditEvent) => void,
    onStatusChange: (s: ConnectionStatus) => void,
  ): () => void {
    onStatusChange(NOT_YET_WIRED);
    return () => {};
  }

  async listWorkers(): Promise<Result<Worker[]>> {
    return notWired();
  }

  async getWorker(): Promise<Result<Worker | null>> {
    return notWired();
  }

  async getAnchorStatus(): Promise<Result<AnchorStatus>> {
    return notWired();
  }

  async updateScope(_actorId: string, _ns: Namespace, _value: ScopeBits): Promise<Result<void>> {
    return notWired();
  }

  async updatePaymentCap(_actorId: string, _perTx: number, _daily: number): Promise<Result<void>> {
    return notWired();
  }

  async revokeDevice(_actorId: string, _intent: RevokeIntent): Promise<Result<void>> {
    return notWired();
  }

  async revokeCap(_actorId: string, _capName: string, _intent: RevokeIntent): Promise<Result<void>> {
    return notWired();
  }

  async enrollK11Begin(input: { userName: string; userDisplayName: string }): Promise<Result<K11EnrollBegin>> {
    try {
      const resp = await fetch(`${this.baseUrl}/v1/k11/enroll/begin`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: input.userName, display_name: input.userDisplayName }),
      });
      if (!resp.ok) {
        const text = await resp.text();
        return { ok: false, status: unreachable(`enroll/begin returned ${resp.status}: ${text}`) };
      }
      const body = await resp.json();
      const opts = body.creation_options?.publicKey ?? body.creation_options ?? {};
      return {
        ok: true,
        data: {
          challenge: opts.challenge ?? '',
          rpId: opts.rp?.id ?? 'localhost',
          rpName: opts.rp?.name ?? 'AgentKeys',
          userId: body.user_id ?? '',
          userName: opts.user?.name ?? input.userName,
          userDisplayName: opts.user?.displayName ?? input.userDisplayName,
          bindingNonce: '',
          pubKeyCredParams: opts.pubKeyCredParams ?? [
            { type: 'public-key', alg: -7 },
            { type: 'public-key', alg: -257 },
          ],
          timeout: opts.timeout ?? 60_000,
        },
      };
    } catch (e) {
      return { ok: false, status: unreachable(`enroll/begin fetch failed: ${(e as Error).message}`) };
    }
  }

  async enrollK11Finish(input: K11EnrollFinishInput): Promise<Result<K11EnrollResult>> {
    try {
      const resp = await fetch(`${this.baseUrl}/v1/k11/enroll/finish`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          user_id: input.bindingNonce,
          credential: {
            id: input.credentialId,
            rawId: input.credentialId,
            response: {
              attestationObject: input.attestationObject,
              clientDataJSON: input.clientDataJSON,
            },
            type: 'public-key',
          },
        }),
      });
      if (!resp.ok) {
        const text = await resp.text();
        return { ok: false, status: unreachable(`enroll/finish returned ${resp.status}: ${text}`) };
      }
      const body = await resp.json();
      return {
        ok: true,
        data: {
          credentialId: body.credential_id,
          registeredAt: body.registered_at_unix,
          chainTxHash: body.chain_tx_hash ?? undefined,
        },
      };
    } catch (e) {
      return { ok: false, status: unreachable(`enroll/finish fetch failed: ${(e as Error).message}`) };
    }
  }
}
