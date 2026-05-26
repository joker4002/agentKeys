export type Namespace = 'personal' | 'family' | 'work' | 'travel';

export type ScopeBits = { read: boolean; write: boolean };

export type ActorRole = 'master' | 'agent';
export type StatusKind = 'ok' | 'warn' | 'bad' | 'muted';

export interface Actor {
  id: string;
  omni: string;
  omniHex: string;
  label: string;
  role: ActorRole;
  parent: string | null;
  derivation: string;
  device: string;
  devicePubkey: string;
  lastActive: string;
  status: StatusKind;
  vendor: string;
  k11: boolean;
  children?: string[];
  scope?: Record<Namespace, ScopeBits>;
  paymentCap?: { perTx: number; daily: number; currency: string };
  timeWindow?: { start: string; end: string; tz: string };
  services?: string[];
}

export type ChipKind =
  | 'default'
  | 'ok'
  | 'warn'
  | 'bad'
  | 'memory'
  | 'creds'
  | 'audit'
  | 'broker'
  | 'chain'
  | 'payment'
  | 'revoke';

export interface AuditEvent {
  id: string;
  ts: string;
  actorId: string;
  actor: string;
  kind: string;
  detail: string;
  chip: ChipKind;
  sev: StatusKind;
  _isNew?: boolean;
}

export interface SimEvent {
  actorId: string;
  actor: string;
  kind: string;
  detail: string;
  chip: ChipKind;
  sev: StatusKind;
}

export interface Worker {
  id: 'memory' | 'credentials' | 'audit' | 'email' | 'payment';
  title: string;
  host: string;
  desc: string;
  callsToday: number;
  callsHour: number;
  p50: number;
  p95: number;
  cap: string;
  byActor: { actor: string; count: number; share: number }[];
}

export type PendingAction =
  | {
      kind: 'revoke-device';
      actor: Actor;
      intent: { text: string; fields: [string, string][] };
    }
  | {
      kind: 'revoke-scope';
      actor: Actor;
      capName: string;
      intent: { text: string; fields: [string, string][] };
    };

export type Route =
  | { page: 'actors'; actorId: null }
  | { page: 'detail'; actorId: string }
  | { page: 'audit'; actorId: null }
  | { page: 'anchor'; actorId: null }
  | { page: 'workers'; actorId: null }
  | { page: 'onboarding'; actorId: null }
  | { page: 'onboarding-mobile'; actorId: null }
  | { page: 'harness'; actorId: null }
  | { page: 'logo'; actorId: null };
