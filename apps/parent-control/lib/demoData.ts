// Static chain/operator display config. Runtime data comes from lib/client.
// ALL fabricated user data (actors, audit events, memory, pairing requests,
// vault) was removed — the app is now driven entirely by the lib/client seam
// (real daemon data, empty states otherwise). See docs/plan/web-flow/issue-9step-flow.md.

import type { CeremonyStep, ChainProfile } from '@/app/_components/types';

// Pairing ceremony narration (the §10.2 master-claim → bind → grant steps).
// Process text only — shown while the real on-chain bind/grant runs.
export const PAIRING_STEPS: CeremonyStep[] = [
  {
    label: 'Verify pairing code',
    sub: 'broker matches the agent-shown code → unbound request (method A)',
    onchain: false,
  },
  {
    label: 'Attest agent device',
    sub: 'fetch D_pub_agent · verify pop_sig (proof-of-possession)',
    onchain: false,
  },
  {
    label: 'Derive child actor',
    sub: 'HDKD //label → O_master//label · public + recomputable',
    onchain: false,
  },
  {
    label: 'Register agent device',
    sub: 'SidecarRegistry.registerAgentDevice(tier=AGENT, roles=CAP_MINT)',
    onchain: true,
    fn: 'registerAgentDevice(bytes32,bytes32,bytes32,bytes,bytes)',
  },
  {
    label: 'Grant scope (Touch ID)',
    sub: 'AgentKeysScope.setScopeWithWebauthn(... requested scope ...)',
    onchain: true,
    fn: 'setScopeWithWebauthn(bytes32,bytes32,bytes,bytes)',
  },
  {
    label: 'Mint initial cap-tokens',
    sub: 'scoped cap-token · ttl 900s',
    onchain: false,
  },
  {
    label: 'Ack binding',
    sub: 'POST /v1/agent/pending-bindings/ack → clears the rendezvous',
    onchain: false,
  },
];

// Chain deployment config (real Heima params; contract addresses are filled by
// the operator's deployment — informational, used for explorer links in the
// audit tx-decode modal below).
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
  block: '—',
  contracts: [
    {
      name: 'AgentKeysScope',
      addr: '—',
      deployedAt: '—',
      purpose: 'per-actor scope grants — services, namespaces, time-windows',
    },
    {
      name: 'SidecarRegistry',
      addr: '—',
      deployedAt: '—',
      purpose:
        'D_pub ↔ (operator_omni, actor_omni, roles) bindings + K11 cred storage',
    },
    {
      name: 'K3EpochCounter',
      addr: '—',
      deployedAt: '—',
      purpose: 'current K3 epoch; bumps trigger KEK derivation rotation',
    },
    {
      name: 'CredentialAudit',
      addr: '—',
      deployedAt: '—',
      purpose: 'per-actor audit log + tier-2 Merkle root anchor every 2 min',
    },
  ],
};
