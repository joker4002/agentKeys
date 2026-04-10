# AgentKeys — Business Pitch Deck

**Date:** 2026-04-09
**Stage:** Pre-seed / v0 building
**Ask:** TBD (seed round or grant)

---

## Slide 1: The Problem

### Every AI agent needs API keys. Setting them up is a nightmare.

AI agents run in cloud sandboxes and need credentials for dozens of services: OpenRouter, Brave Search, Notion, GitHub, OpenAI, Google APIs. Today, developers:

- **Manually create accounts** on each service, per agent
- **Copy-paste API keys** into `.env` files inside sandboxes
- **Have zero revocation** — if an agent is compromised, the attacker gets permanent keys with no TTL
- **Have zero audit trail** — no way to know which agent accessed which credential, when
- **Have zero scoping** — every agent sees every key in the `.env` file

This is the 2024 way of doing things in a 2026 world where 40% of enterprise apps will include AI agents (Gartner) and the AI agents market is projected at **$11.78B in 2026** growing to **$251.38B by 2034** (46.6% CAGR).

---

## Slide 2: The Market

### AI Agent Infrastructure is a $90B market in 2026

```
AI Agents Market          AI Infrastructure Market
$11.78B (2026)            $90B (2026)
  → $251.38B (2034)         → $465B (2033)
  CAGR: 46.6%               CAGR: 24%
```

**Adoption signals:**
- 50% of enterprises using GenAI will deploy autonomous agents by 2027 (2x from 2025)
- Major sandbox platforms (E2B, agent-infra, Northflank, Modal) all shipping in 2026
- x402 payment protocol: 119M+ transactions processed, $600M annualized volume
- Claude Code, OpenClaw, Codex, Cursor — every dev tool is becoming agent-powered

**The credential layer is missing.** Sandbox providers give you compute. LLM providers give you intelligence. Nobody gives you credentials — the auth layer that connects agents to the services they need.

---

## Slide 3: The Solution

### AgentKeys: scoped, revocable, audited credentials for AI agents

```
Developer (CLI)              AgentKeys                    Agent (MCP)
                                │
  agentkeys store ──────────►   │   ◄──── agentkeys.get_credential
  agentkeys revoke ─────────►   │   ◄──── agentkeys.provision
  agentkeys usage ──────────►   │
  agentkeys approve ────────►   │
                                │
                         ┌──────┴──────┐
                         │   Backend   │
                         │  (v0: mock) │
                         │  (v0.1: TEE)│
                         └─────────────┘
```

**Two interfaces, one credential lifecycle:**
- **CLI for humans:** `agentkeys store`, `read`, `revoke`, `approve` — manage credentials like 1Password
- **MCP for agents:** `agentkeys.get_credential`, `agentkeys.provision` — agents consume and even auto-provision credentials autonomously

**The killer feature:** `agentkeys.provision(service: "openrouter")` — an agent with browser control creates a real OpenRouter account, obtains the API key, and stores it. No human intervention. Fresh sandbox, instant keys.

---

## Slide 4: How It Works

### Four user stories, each is a demo

**Story 1: Store + Use + Revoke (the 1Password upgrade)**
```
agentkeys store my-agent openrouter sk-xxx    # human stores a key
# Agent calls MCP: get_credential("openrouter") → sk-xxx
agentkeys revoke my-agent                     # human kills access
# Agent calls MCP: get_credential("openrouter") → DENIED
```
One revoke. Instant. Across all tools.

**Story 2: MCP Auth for Claude Code (the wrapper pattern)**
```json
// Before: hardcoded token in settings.json
{"env": {"GITHUB_TOKEN": "ghp_xxxx..."}}

// After: AgentKeys manages it
{"command": "agentkeys", "args": ["run", "my-agent", "--", "npx", "@mcp/server-github"]}
```
Every MCP server gets scoped, revocable, audited credentials. Zero server-side changes.

**Story 3: Auto-Provisioning (the magic moment)**
Agent calls `agentkeys.provision(service: "openrouter")` → Playwright opens a browser, creates a real account, obtains the key, encrypts it, stores it. 30 seconds. No human. The agent set up its own credentials.

**Story 4: Ephemeral Recovery (cloud LLM)**
Cloud LLM sandbox dies. User starts a new chat. Types: "recover agent-A." New daemon starts, shows a pair code, user approves on their Mac. Same wallet, same credentials. No re-provisioning.

---

## Slide 5: Business Model

### Three revenue layers that stack

| Layer | How it works | Revenue type | When |
|---|---|---|---|
| **1. Platform fee** | Free for 3 agents. $9/mo per additional agent. Enterprise: custom pricing, self-hosted option, compliance features. | SaaS subscription | v0.1 (after Heima integration) |
| **2. Provisioning margin** | Auto-provisioned accounts cost $0.50-2.00 per account (covers browser automation compute + burner email). Passed through to user via x402 micro-payment. | Per-transaction | v0 |
| **3. Paymaster margin** | For fiat users (China, SEA): convert CNY/local currency to HEI (gas) + USDC (service payments). 2-3% payment processing spread. | Payment processing | v0.2 |

**Unit economics at scale (1,000 paying users):**
- 1,000 users x avg 5 agents x $9/agent/mo = **$45K MRR**
- Provisioning: 5,000 agents x 3 services x $1 = **$15K one-time**
- Paymaster (20% fiat): 200 users x $20/mo margin = **$4K MRR**
- **Total: ~$49K MRR / ~$588K ARR at 1,000 users**

**Long-term moat:** the identity graph. Every agent wallet, every linked identity, every credential scope creates network effects. The more agents use AgentKeys, the richer the identity graph, the easier recovery and cross-agent coordination become.

---

## Slide 6: Competitive Landscape

### We're the only one built for agents, not humans

| | AgentKeys | Composio ($29M raised) | 1Password CLI | Doppler | Infisical |
|---|---|---|---|---|---|
| **Built for** | AI agents | AI agents + integrations | Humans + teams | DevOps teams | DevOps teams |
| **MCP-native** | Yes (MCP tools) | Yes (SDK) | No | No | No |
| **Auto-provision** | Yes (Playwright) | No (pre-built connectors) | No | No | No |
| **Instant revocation** | ≤6s (on-chain) | API-dependent | Manual | API call | API call |
| **Audit trail** | On-chain (tamper-proof) | Vendor log | Vendor log | Vendor log | Self-hosted log |
| **Scoped per-agent** | Yes (child sessions) | Partially (per-connection) | No (shared vault) | Partially (env-specific) | Yes (projects) |
| **Crypto-native billing** | Yes (x402 + HEI) | No | No | No | No |
| **Open source** | Yes (MIT/Apache-2.0) | Partially | No | No | Yes |
| **Self-sovereign** | Yes (TEE, no vendor lock) | No (vendor-hosted) | No | No | Partially |
| **Pricing** | Free 3 agents, $9/agent/mo | Free tier + $29/mo | $7.99/user/mo | $21/user/mo | $18/user/mo |

### Key differentiators vs Composio (closest competitor)

Composio is an integration platform — 850 pre-built connectors, OAuth handling, managed auth. They abstract existing service APIs. AgentKeys is different:

1. **We create accounts.** Composio connects to accounts you already have. AgentKeys creates the accounts from scratch via browser automation. Fresh sandbox → instant keys.
2. **We're crypto-native.** x402 payments, on-chain audit, TEE-secured storage. Composio is a centralized SaaS.
3. **We're self-sovereign.** User's master key lives in a TEE, not a vendor's database. No vendor lock-in, no vendor can read your secrets.
4. **We're open source.** MIT OR Apache-2.0. Composio is partially open.

---

## Slide 7: Go-to-Market

### Wedge: the developer who just set up their 5th agent sandbox

**Phase 1: Developer community (v0, now)**
- 10 trusted users, meetup demo, GitHub launch
- Target: developers running OpenClaw / Claude Code who are tired of `.env` files
- Distribution: Hacker News launch, AI agent community Discord/Slack, dev.to posts
- Hook: "Store once, revoke everywhere" — the 1Password-for-agents pitch
- Metric: 100 GitHub stars, 50 installs in first month

**Phase 2: Agent framework integrations (v0.1)**
- Official integration with Claude Code (MCP auth wrapper pattern)
- OpenClaw skill / plugin
- Cursor MCP server config template
- Partnership with sandbox providers (E2B, agent-infra, Northflank)
- Metric: 500 active agents using AgentKeys

**Phase 3: Enterprise + regulated markets (v0.2+)**
- Self-hosted mock backend for enterprises with compliance requirements
- Paymaster for China/SEA markets (Alipay, GrabPay)
- SOC 2 compliance (when Heima TEE integration lands)
- Metric: first enterprise contract, first paymaster deployment

**Phase 4: Platform (v1.0)**
- Agent marketplace: developers publish provisioner scripts for new services
- Identity graph as a platform primitive: cross-agent coordination, reputation
- x402 billing aggregation: agents pay for services via AgentKeys, we aggregate micro-payments
- Metric: 10K agents, $100K MRR

---

## Slide 8: Why Now

### Three tailwinds converging in 2026

**1. AI agents are going autonomous.**
Claude Code, OpenClaw, Codex, Devin — agents are no longer chatbots. They run code, browse the web, call APIs, manage infrastructure. They need real credentials, not toy demos.

**2. x402 payment protocol just shipped.**
119M+ transactions, $600M annualized volume, zero protocol fees. AI agents can now pay for services autonomously via USDC on Base. The payment layer exists — the credential layer doesn't.

**3. Sandbox platforms are commoditizing.**
E2B (used by half of Fortune 500), agent-infra, Northflank, Modal — compute for agents is solved. What's missing is the auth layer that connects compute to services. We fill that gap.

**The window:** right now, every developer solves this with `.env` files. The first tool that makes "fresh sandbox, instant keys" a one-command experience wins the category. That window closes when the major sandbox providers build their own credential layers (they will — but they'll build vendor-locked versions, not open/self-sovereign ones).

---

## Slide 9: Tech Moat

### What's hard to replicate

1. **Browser automation provisioning engine.** Each service has unique signup flows, CAPTCHAs, email verification, ToS nuances. Our Playwright scripts are battle-tested per service. This is a grind, not a breakthrough — moat grows linearly with services covered.

2. **On-chain revocation with TEE security.** Built on Heima parachain — TEE-attested credential storage, on-chain audit trail, ≤6s revocation propagation. Competitors would need to build or adopt equivalent blockchain infrastructure.

3. **Identity graph.** Agent wallet addresses + linked identities (email, alias, ENS) + credential scopes + audit history. This graph compounds: more agents → richer identity data → easier recovery, better scoping, cross-agent coordination.

4. **Open source + self-sovereign.** MIT OR Apache-2.0 licensed. No vendor lock-in. Users can run the mock backend themselves. This is a wedge for enterprise adoption where "we can't send our secrets to a SaaS vendor" is a hard requirement.

5. **Two-layer payment model.** HEI for system gas (Heima chain operations) + USDC on Base Chain for service payments (x402). Paymaster for fiat users. This multi-rail approach works in crypto-friendly AND crypto-restricted jurisdictions — most competitors are one or the other.

---

## Slide 10: Architecture (for technical investors)

```
┌─ User's Mac ──────────────────┐
│ agentkeys CLI                  │
│ Session key in OS keychain     │
└───────────┬────────────────────┘
            │ HTTPS (session-authenticated)
            ▼
┌─ Credential Backend ──────────┐
│ v0: Mock (axum + SQLite)       │
│ v0.1: Heima TEE + pallets      │
│                                │
│ Master key custody + signing   │
│ Rendezvous relay (OTP pairing) │
│ Auth-request primitive         │
│ Credential blob storage        │
│ Scope enforcement              │
│ Audit log                      │
└───────────┬────────────────────┘
            │
    ┌───────┴────────┐
    ▼                ▼
┌─ Agent Sandbox ─┐  ┌─ Cloud LLM ───────┐
│ agentkeys-daemon │  │ @agentkeys/daemon  │
│ MCP server       │  │ (npm package)      │
│ memfd_secret     │  │ Ephemeral + recover│
│ seccomp-bpf      │  └───────────────────┘
└──────────────────┘
```

**Key technical decisions:**
- `CredentialBackend` trait abstracts over backends — swap mock for Heima TEE without any CLI/daemon changes
- Child-initiates pairing via rendezvous relay — works across local Docker, cloud VMs, and cloud LLM sandboxes without direct network routes
- Monorepo, Rust for all trust-boundary code, TypeScript only for disposable Playwright scripts
- Kernel hardening verified empirically on stock `agent-infra/sandbox v1.0.0.152`

---

## Slide 11: Roadmap

| Milestone | Timeline | What ships | Business impact |
|---|---|---|---|
| **v0** | Now + 5 weeks | CLI + daemon + mock backend + OpenRouter provisioner + MCP auth wrapper | 10 beta users, meetup demo, GitHub launch |
| **v0.1** | +4 weeks after v0 | Heima TEE integration (replace mock backend), real on-chain audit + revocation | "Built on blockchain" credibility, TEE security claim |
| **v0.2** | +4 weeks after v0.1 | Hardened sandbox fork, paymaster for fiat markets, 3 more provisioner scripts (Brave, Notion, OpenAI) | Enterprise pilot, China/SEA market entry |
| **v1.0** | +3 months after v0.2 | Phone app (QR code approval), web dashboard, provisioner marketplace, x402 billing aggregation | 10K agents, $100K MRR target |

---

## Slide 12: Team

*[To be filled — include founder backgrounds, relevant experience in crypto/infra/security/developer tools]*

**Key hires needed:**
- Playwright automation engineer (provisioner scripts for Tier 2/3 services)
- Heima/Substrate developer (TEE integration, pallet development)
- Developer advocate (docs, community, integrations)

---

## Slide 13: The Ask

*[To be filled based on fundraising strategy]*

**Suggested seed round framing:**

- **Use of funds:** 12-18 months runway for a 3-person team (founder + 2 engineers)
- **Milestones to hit:** v0 launch → v0.1 Heima integration → first 500 active agents → first enterprise pilot → v0.2 with paymaster
- **Key metric:** number of active agents using AgentKeys as their credential layer
- **Why now:** the window between "AI agents need credentials" and "every sandbox vendor builds their own locked-in version" is 12-18 months

---

## Appendix A: Why Not Just Use 1Password / Doppler / Infisical?

| Pain Point | 1Password | Doppler/Infisical | AgentKeys |
|---|---|---|---|
| Create an API key for a new agent | Manual: go to service dashboard, create key, copy, paste | Manual: same, then import into vault | **Automatic:** `agentkeys.provision` creates the account + key |
| Agent needs a key at runtime | Read from shared vault (all agents see all keys) | Read from env var (injected at deploy) | **MCP tool call** with per-agent scope enforcement |
| Compromise detected | Manually rotate the key on the service dashboard | Manually rotate | **`agentkeys revoke`** — instant, on-chain, all tools lose access at once |
| Audit: which agent used which key when? | 1Password activity log (opaque) | Dashboard logs | **On-chain audit trail** — tamper-proof, queryable |
| Agent dies, new sandbox | Re-configure from scratch | Re-deploy with same env vars | **`agentkeys-daemon --recover agent-A`** — same credentials, new sandbox |
| Cloud LLM (ChatGPT, Claude.ai) | Not supported | Not supported | **`npx @agentkeys/daemon`** — pair via OTP, scoped child session |

## Appendix B: x402 Integration Opportunity

x402 (Coinbase's open payment protocol) processed 119M+ transactions and $600M annualized volume by March 2026. It enables AI agents to pay for APIs using USDC on Base Chain.

AgentKeys sits at the intersection of x402 and MCP:
- Agent needs an API key → AgentKeys provides it via MCP
- Agent needs to pay for the API call → x402 handles it via USDC
- AgentKeys tracks both credential access AND payment in the same audit trail

**Future opportunity:** AgentKeys as the billing aggregator for agent API usage. Instead of each agent wallet paying each service directly, AgentKeys batches micro-payments (reducing gas costs by 10-100x) and provides a unified spending dashboard.

## Appendix C: References

- [AI Agents Market Size (2026-2034)](https://www.demandsage.com/ai-agents-market-size/)
- [Agentic AI Market Forecast](https://www.fortunebusinessinsights.com/agentic-ai-market-114233)
- [AI Infrastructure Market Size](https://www.coherentmarketinsights.com/industry-reports/ai-infrastructure-market)
- [Composio Funding ($29M Series A)](https://siliconangle.com/2025/07/22/composio-raises-25m-funding-ease-ai-agent-development/)
- [x402 Protocol — Coinbase](https://docs.cdp.coinbase.com/x402/welcome)
- [x402 Whitepaper](https://www.x402.org/x402-whitepaper.pdf)
- [x402 on Stellar](https://stellar.org/blog/foundation-news/x402-on-stellar)
- [Agent-Infra AIO Sandbox](https://www.marktechpost.com/2026/03/29/agent-infra-releases-aio-sandbox-an-all-in-one-runtime-for-ai-agents-with-browser-shell-shared-filesystem-and-mcp/)
- [E2B — Enterprise AI Agent Cloud](https://e2b.dev/)
- [Kimi Claw Launch](https://www.marktechpost.com/2026/02/15/moonshot-ai-launches-kimi-claw-native-openclaw-on-kimi-com-with-5000-community-skills-and-40gb-cloud-storage-now/)
- [Secrets Management Tools Comparison 2026](https://guptadeepak.com/top-5-secrets-management-tools-hashicorp-vault-aws-doppler-infisical-and-azure-key-vault-compared/)
- [AI Agent Authentication Platforms Comparison](https://composio.dev/content/ai-agent-authentication-platforms)
