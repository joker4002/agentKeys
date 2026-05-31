// Seed data for the 9-step operator-flow demo (Claude-design port).
// M1 visible flow; real-daemon wiring is Phase 2 behind the lib/client seam.
// See docs/plan/web-flow/issue-9step-flow.md.

import type {
  Actor,
  AuditEvent,
  CeremonyStep,
  ChainProfile,
  PairingRequest,
  PreservedMemory,
  SimEvent,
} from '@/app/_components/types';

export const INITIAL_ACTORS: Actor[] = [
  {
    id: 'master', omni: 'O_master', omniHex: '0xa3f1...c92e', label: 'Sara (master)',
    role: 'master', parent: null, derivation: '/', device: 'iPhone 17 Pro · Secure Enclave',
    devicePubkey: 'D_pub_master_iphone', lastActive: 'now', status: 'ok', vendor: 'self', k11: true,
    children: ['agent-folotoy', 'agent-chatgpt', 'agent-pluto', 'agent-claude'],
  },
  {
    id: 'agent-folotoy', omni: 'O_master//folotoy', omniHex: '0x7c2d...41a9', label: 'FoloToy bear',
    role: 'agent', parent: 'master', derivation: '//folotoy', device: 'FoloToy hardware · v2.3.1',
    devicePubkey: 'D_pub_folotoy_2024', lastActive: '2m ago', status: 'ok', vendor: 'FoloToy Inc.', k11: false,
    scope: { personal: { read: true, write: true }, family: { read: true, write: false }, work: { read: false, write: false }, travel: { read: false, write: false } },
    paymentCap: { perTx: 5, daily: 20, currency: 'USDC' }, timeWindow: { start: '07:00', end: '20:30', tz: 'local' },
    services: ['memory', 'audit', 'payment'],
  },
  {
    id: 'agent-chatgpt', omni: 'O_master//chatgpt', omniHex: '0xb1e9...3f04', label: 'ChatGPT (cloud)',
    role: 'agent', parent: 'master', derivation: '//chatgpt', device: 'OpenAI sandbox · ephemeral',
    devicePubkey: 'D_pub_chatgpt_eph', lastActive: '14m ago', status: 'ok', vendor: 'OpenAI', k11: false,
    scope: { personal: { read: true, write: false }, family: { read: false, write: false }, work: { read: true, write: true }, travel: { read: true, write: false } },
    paymentCap: { perTx: 0, daily: 0, currency: 'USDC' }, timeWindow: { start: '00:00', end: '24:00', tz: 'local' },
    services: ['credentials', 'memory', 'audit'],
  },
  {
    id: 'agent-pluto', omni: 'O_master//pluto', omniHex: '0x5a44...9b2f', label: 'Pluto (home robot)',
    role: 'agent', parent: 'master', derivation: '//pluto', device: 'Pluto v1 · TPM 2.0',
    devicePubkey: 'D_pub_pluto_v1', lastActive: '38m ago', status: 'warn', vendor: 'Pluto Labs', k11: false,
    scope: { personal: { read: true, write: true }, family: { read: true, write: true }, work: { read: false, write: false }, travel: { read: false, write: false } },
    paymentCap: { perTx: 2, daily: 5, currency: 'USDC' }, timeWindow: { start: '06:00', end: '22:00', tz: 'local' },
    services: ['memory', 'audit', 'email'],
  },
  {
    id: 'agent-claude', omni: 'O_master//claude', omniHex: '0xd7c0...8e15', label: 'Claude (research)',
    role: 'agent', parent: 'master', derivation: '//claude', device: 'Anthropic sandbox · ephemeral',
    devicePubkey: 'D_pub_claude_eph', lastActive: '3h ago', status: 'muted', vendor: 'Anthropic', k11: false,
    scope: { personal: { read: false, write: false }, family: { read: false, write: false }, work: { read: true, write: true }, travel: { read: false, write: false } },
    paymentCap: { perTx: 0, daily: 0, currency: 'USDC' }, timeWindow: { start: '00:00', end: '24:00', tz: 'local' },
    services: ['credentials', 'memory', 'audit'],
  },
];

export const INITIAL_EVENTS: AuditEvent[] = [
  { id: 'e-501', ts: '14:32:08', actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'memory.read', detail: 'family/bedtime-story #14', chip: 'memory', sev: 'ok' },
  { id: 'e-500', ts: '14:31:54', actorId: 'agent-pluto', actor: 'Pluto', kind: 'memory.read', detail: 'family/grocery-list', chip: 'memory', sev: 'ok' },
  { id: 'e-499', ts: '14:31:22', actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'payment.attempt', detail: 'FoloToy Store · $2.99 · Lullabies pack #03', chip: 'payment', sev: 'warn' },
  { id: 'e-498', ts: '14:30:11', actorId: 'agent-chatgpt', actor: 'ChatGPT', kind: 'cred.fetch', detail: 'work/openrouter (cap=cred:r, ttl=300s)', chip: 'creds', sev: 'ok' },
  { id: 'e-497', ts: '14:28:47', actorId: 'agent-pluto', actor: 'Pluto', kind: 'memory.write', detail: 'family/lights-routine (3 entries)', chip: 'memory', sev: 'ok' },
  { id: 'e-496', ts: '14:27:30', actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'memory.read', detail: 'personal/bedtime-pref', chip: 'memory', sev: 'ok' },
  { id: 'e-495', ts: '14:26:02', actorId: 'agent-chatgpt', actor: 'ChatGPT', kind: 'audit.append', detail: 'session.start · sid=8e2c…', chip: 'audit', sev: 'ok' },
  { id: 'e-494', ts: '14:24:58', actorId: 'agent-pluto', actor: 'Pluto', kind: 'cap.mint', detail: 'memory:read scope=family ttl=900s', chip: 'broker', sev: 'ok' },
  { id: 'e-493', ts: '14:23:11', actorId: 'master', actor: 'Sara (master)', kind: 'anchor.batch', detail: 'tier-2 anchor · root=0x7e3f… · 128 events', chip: 'chain', sev: 'ok' },
  { id: 'e-492', ts: '14:21:40', actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'memory.read', detail: 'family/movies-watched', chip: 'memory', sev: 'ok' },
  { id: 'e-491', ts: '14:20:33', actorId: 'agent-claude', actor: 'Claude', kind: 'cred.fetch', detail: 'work/anthropic-api (cap=cred:r)', chip: 'creds', sev: 'ok' },
  { id: 'e-490', ts: '14:18:09', actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'payment.attempt', detail: 'FoloToy Store · $1.99 · Story pack', chip: 'payment', sev: 'warn' },
];

export const SIM_EVENTS: SimEvent[] = [
  { actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'memory.read', detail: 'family/bedtime-story #15', chip: 'memory', sev: 'ok' },
  { actorId: 'agent-pluto', actor: 'Pluto', kind: 'memory.read', detail: 'family/lights-routine', chip: 'memory', sev: 'ok' },
  { actorId: 'agent-chatgpt', actor: 'ChatGPT', kind: 'cred.fetch', detail: 'work/openrouter (cap=cred:r)', chip: 'creds', sev: 'ok' },
  { actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'memory.read', detail: 'personal/songs-favourite', chip: 'memory', sev: 'ok' },
  { actorId: 'agent-pluto', actor: 'Pluto', kind: 'audit.append', detail: 'door.unlock · front · authorized', chip: 'audit', sev: 'ok' },
  { actorId: 'agent-folotoy', actor: 'FoloToy bear', kind: 'payment.attempt', detail: 'FoloToy Store · $4.99 · Premium pack', chip: 'payment', sev: 'warn' },
  { actorId: 'agent-chatgpt', actor: 'ChatGPT', kind: 'memory.write', detail: 'work/notes (1 entry)', chip: 'memory', sev: 'ok' },
];

// Onboarding ceremony (Flow 1 · arch §22c) — real WebAuthn assertion, narrated backend steps (M1).
export const ONBOARDING_STEPS: CeremonyStep[] = [
  { label: 'WebAuthn assertion', sub: 'platform authenticator · iOS Secure Enclave · K11 verified', onchain: false },
  { label: 'Identity fingerprint', sub: 'sha256(provider="apple" ‖ email) → recoverable master identity', onchain: false },
  { label: 'Resolve OmniAccount', sub: 'first login → create O_master · HDKD root at /', onchain: true, fn: 'createOmniAccount(bytes32)' },
  { label: 'Derive master wallet', sub: 'K3 epoch v1 · secp256k1 · 0xf3a8…b1d2', onchain: false },
  { label: 'Register master device', sub: 'SidecarRegistry.registerMasterDevice(D_pub, K11_cred, roles=7)', onchain: true, fn: 'registerMasterDevice(bytes32,bytes32,uint8)' },
  { label: 'Provision vault infra', sub: 'S3 bucket + IAM role + bucket-policy · 4/4 sub-scripts ok', onchain: false },
  { label: 'Verify chain contracts', sub: '4/4 stage-1 contracts live on heima · chain_id 212013', onchain: false },
  { label: 'Open session', sub: 'K6 session JWT · ttl 18000s · stored in Keychain (biometric-gated)', onchain: false },
  { label: 'Subscribe audit stream', sub: 'tier-1 SSE · /v1/audit/stream · auto-reconnect', onchain: false },
];

// Pairing ceremony (§10.2 — master binds + grants after the agent redeems a link-code).
export const PAIRING_STEPS: CeremonyStep[] = [
  { label: 'Verify pair-code', sub: 'rendezvous code 7F3K-9QA2 matches agent broadcast', onchain: false },
  { label: 'Attest agent device', sub: 'fetch D_pub_hermes · verify ephemeral-pod attestation quote', onchain: false },
  { label: 'Derive child actor', sub: 'HDKD //hermes → O_master//hermes · hard derivation', onchain: false },
  { label: 'Register agent device', sub: 'SidecarRegistry.registerDevice(tier=2, roles=cap-mint)', onchain: true, fn: 'registerDevice(bytes32,bytes32,uint8,uint8)' },
  { label: 'Write scope grant', sub: 'AgentKeysScope.setScopeWithWebauthn(memory:rw · personal,travel)', onchain: true, fn: 'setScopeWithWebauthn(bytes32,bytes32,bytes,bytes)' },
  { label: 'Mint initial cap-tokens', sub: 'memory:read ttl 900s · scope=personal,travel', onchain: false },
  { label: 'Append audit entry', sub: 'CredentialAudit.append(op=pair, actor=hermes)', onchain: true, fn: 'append(bytes32,bytes32,bytes32)' },
  { label: 'Hand session to agent', sub: 'broadcast SSE → hermes receives K6 child session key', onchain: false },
];

export const PRESERVED_MEMORY: PreservedMemory[] = [
  { ns: 'personal', key: 'profile', title: 'profile.md', bytes: 412, version: 'v2', updated: 'just now',
    preview: 'Name: Kevin Zhao · base: Chengdu, Sichuan · prefers spicy food, allergic to cilantro',
    body: '# profile\n\nname: Kevin Zhao\nbase: Chengdu, Sichuan\nlanguages: zh-CN, en\nfood: loves málà hotpot; ALLERGIC to cilantro (coriander)\nwork: customs broker; handles cross-border e-commerce filings\nvoice: prefers concise answers, no preamble' },
  { ns: 'personal', key: 'preferences', title: 'preferences.md', bytes: 196, version: 'v2', updated: 'just now',
    preview: 'Wake 06:30 · commute by metro line 1 · bedtime stories for daughter Mia (age 5)',
    body: '# preferences\n\nwake: 06:30\ncommute: Chengdu Metro line 1\nfamily: daughter Mia, age 5 — bedtime stories nightly\nmusic: lo-fi while working, no lyrics' },
  { ns: 'family', key: 'household', title: 'household.md', bytes: 254, version: 'v2', updated: 'just now',
    preview: 'Members: Kevin, Lin (spouse), Mia (5) · home robot Pluto manages lights + locks',
    body: '# household\n\nmembers: Kevin, Lin (spouse), Mia (age 5)\nhome devices: Pluto robot (lights, locks), FoloToy bear (Mia)\nroutines: lights off 21:00; front door auto-lock 22:00' },
  { ns: 'travel', key: 'chengdu-trip', title: 'chengdu-2026.md', bytes: 188, version: 'v2', updated: 'just now',
    preview: 'Chengdu trip May 25–29 · follow up on customs question from 05-24 meeting',
    body: '# chengdu-2026\n\ndates: 2026-05-25 → 2026-05-29\npurpose: customs clarification meeting\nopen item: follow up on HS-code question raised 05-24\nhotel: Niccolo Chengdu' },
  { ns: 'work', key: 'projects', title: 'projects.md', bytes: 167, version: 'v2', updated: 'just now',
    preview: 'Active: Q2 cross-border filing automation · OpenRouter key budget $20/day',
    body: '# projects\n\nactive: Q2 cross-border filing automation\ntools: OpenRouter (LLM), brave-search\nbudget: $20/day LLM spend cap' },
];

// Incoming pairing request (post-#149: a pending binding — the agent already redeemed a link-code).
export const INCOMING_PAIRING: PairingRequest = {
  id: 'pair-hermes-001',
  agent: 'Hermes',
  vendor: 'NousResearch · hermes-agent',
  device: 'aiosandbox · ephemeral pod',
  machine: 'sandbox-us-east-1b · pod hermes-7f3k',
  runtime: 'task-host · hermes (arch §22d)',
  dpub: 'D_pub_hermes_3f9c1ab8a17d04',
  dpubFull: '0x3f9c1ab8a17d042055ffec84dba9c4027e3f9c1ab8a17d042055ffec84dba9c40',
  pairCode: '7F3K-9QA2',
  derivation: '//hermes',
  requested: [
    { cap: 'memory:read', ns: ['personal', 'travel'], reason: 'inject your profile + trip context at session start' },
    { cap: 'memory:write', ns: ['travel'], reason: 'record new travel facts it learns in conversation' },
    { cap: 'audit:append', ns: ['own log'], reason: 'write its own tamper-evident activity log' },
  ],
  requestedAt: 'just now',
  attestation: 'TEE quote verified · sandbox image agentkeys-hermes:v0.4',
};

export interface VaultItem {
  service: string;
  className: string;
  actor: string;
  actorLabel: string;
  bytes: number;
  version: string;
  written: string;
  readCount: number;
  status: 'ok' | 'stale';
}

export const VAULT_ITEMS: VaultItem[] = [
  { service: 'openrouter', className: 'class-B', actor: 'agent-folotoy', actorLabel: 'FoloToy bear', bytes: 161, version: 'v2', written: '14:30:11', readCount: 14, status: 'ok' },
  { service: 'anthropic', className: 'class-B', actor: 'agent-claude', actorLabel: 'Claude', bytes: 213, version: 'v2', written: '14:18:09', readCount: 9, status: 'ok' },
  { service: 'brave-search', className: 'class-B', actor: 'agent-chatgpt', actorLabel: 'ChatGPT', bytes: 144, version: 'v2', written: '14:11:44', readCount: 32, status: 'ok' },
  { service: 'spotify', className: 'class-B', actor: 'agent-pluto', actorLabel: 'Pluto', bytes: 198, version: 'v2', written: '13:58:02', readCount: 4, status: 'ok' },
];

export const CHAIN_PROFILE: ChainProfile = {
  name: 'heima',
  display: 'Heima Network · Litentry parachain mainnet',
  chainId: 212013,
  kind: 'substrate-frontier',
  rpc: 'https://rpc.heima.network',
  wss: 'wss://rpc.heima.network',
  substrateWss: 'wss://rpc.heima.network',
  explorer: 'https://heima.statescan.io',
  tokenSymbol: 'HEI',
  tokenDecimals: 18,
  finality: 'latest (instant)',
  block: '4 821 022',
  contracts: [
    { name: 'AgentKeysScope', addr: '0x3a91f2ec842055ff7e3f9c1ab8a17d04dba9c402', deployedAt: 'block 4 819 110', purpose: 'per-actor scope grants — services, namespaces, time-windows' },
    { name: 'SidecarRegistry', addr: '0xa3f1c92e7e3f9c1ab8a17d042055ffec84dba9c4', deployedAt: 'block 4 819 112', purpose: 'D_pub ↔ (operator_omni, actor_omni, roles) bindings + K11 cred storage' },
    { name: 'K3EpochCounter', addr: '0x7e3f9c1a3a91f2ec842055ffb8a17d04dba9c4d8', deployedAt: 'block 4 819 113', purpose: 'current K3 epoch; bumps trigger KEK derivation rotation' },
    { name: 'CredentialAudit', addr: '0x1bc402e8c39b3a91f2ecb8a17d047e3f9c1a2055', deployedAt: 'block 4 819 114', purpose: 'per-actor audit log + tier-2 Merkle root anchor every 2 min' },
  ],
};

// ─── Heima TX helpers (deterministic mock; real decode = GH #153) ──
export function txHash(seed: string): string {
  let h = 0;
  const s = String(seed);
  for (let i = 0; i < s.length; i++) h = (((h << 5) - h + s.charCodeAt(i)) | 0);
  const hex = (n: number) => Math.abs(n).toString(16).padStart(8, '0');
  return '0x' + hex(h) + hex(h * 7 + 13) + hex(h * 31 + 5) + hex(h * 131 + 9);
}

const CALLDATA_MAP: Record<string, { sel: string; fn: string }> = {
  'memory.read': { sel: '0x6c1a9f33', fn: 'memoryRead(bytes32,bytes32)' },
  'memory.write': { sel: '0x9d2bce10', fn: 'memoryWrite(bytes32,bytes32,bytes32)' },
  'cred.fetch': { sel: '0x3a7f10cd', fn: 'credentialFetch(bytes32,bytes32)' },
  'cap.mint': { sel: '0x1f4c0a92', fn: 'capMint(bytes32,uint8,uint64)' },
  'cap.revoked': { sel: '0xa98bbce0', fn: 'capRevoke(bytes32,bytes32)' },
  'device.revoked': { sel: '0xd34c7e11', fn: 'revokeDevice(bytes32,bytes[])' },
  'audit.append': { sel: '0x0c44b209', fn: 'append(bytes32,bytes32,bytes32)' },
  'anchor.batch': { sel: '0x77ae5d8c', fn: 'appendRoot(bytes32,uint32)' },
  'cap.pair': { sel: '0x2bd1f409', fn: 'registerDevice(bytes32,bytes32,uint8,uint8)' },
  'device.paired': { sel: '0x2bd1f409', fn: 'registerDevice(bytes32,bytes32,uint8,uint8)' },
  'scope.grant': { sel: '0x8e21c4aa', fn: 'setScopeWithWebauthn(bytes32,bytes32,bytes,bytes)' },
  'payment.attempt': { sel: '0x4f0ab219', fn: 'paymentExecute(bytes32,uint256,bytes32)' },
};

// MOCK calldata decode (event-kind → selector + signature). Real decode = GH #153.
export function decodeCalldata(ev: { kind: string }): { sel: string; fn: string } {
  return CALLDATA_MAP[ev.kind] || { sel: '0x00000000', fn: (ev.kind || 'event') + '(bytes)' };
}

export const ONCHAIN_KINDS = new Set<string>([
  'anchor.batch', 'cap.mint', 'cap.revoked', 'device.revoked', 'cap.pair', 'scope.grant', 'audit.append',
]);

export function contractFor(kind: string): string {
  if (kind === 'anchor.batch' || kind === 'audit.append') return 'CredentialAudit';
  if (kind === 'scope.grant') return 'AgentKeysScope';
  if (kind === 'cap.pair' || kind === 'device.revoked') return 'SidecarRegistry';
  return 'Broker';
}
