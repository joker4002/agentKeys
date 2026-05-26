# AgentKeys · parent control (M1)

Phase 1 mobile-responsive web UI for the AgentKeys M1 demo. Resolves [issue #110](https://github.com/litentry/agentKeys/issues/110).

Design handoff source: Claude Design — iii.dev-inspired aesthetic (IBM Plex Mono + Serif, cream/ink palette, hairline rules, ASCII separators, per-section accent hues).

## Pages

- **actors** — HDKD tree + devices/agents table with stats strip
- **actor detail** — per-namespace scope toggles (deny / read / read+write), payment-cap inputs, live cap-tokens table with per-cap revoke
- **audit feed** — live SSE stream filterable by worker, click any row for full event detail
- **anchor status** — countdown to next tier-2 batch + recent Merkle roots with explorer links
- **workers** — five worker cards (memory, credentials, audit, email, payment) with per-actor usage share; click a card to see trust profile
- **onboarding** — first-run wizard mirroring [`harness/v2-stage1-demo.sh`](../../harness/v2-stage1-demo.sh) steps (real WebAuthn lands in PR-B)
- **onboarding/mobile** — stub for adding a second master device via QR pairing (real cross-device WebAuthn lands in M5)
- **logo** — six Bedlington Terrier variants (profile, front-cute, cloud, monogram, seal, icon) for brand exploration

## Data layer

All reads + writes flow through a single [`AgentKeysClient`](lib/client/types.ts) interface implemented under [`lib/client/`](lib/client/). The default implementation is `EmptyBackend` — every call returns a `{ ok: false, status: { kind: 'disconnected', reason: 'no-backend-configured' } }` discriminant, and the UI renders explicit empty states with copy explaining what's missing.

| Backend | When | Status |
|---|---|---|
| `EmptyBackend`  | `NEXT_PUBLIC_AGENTKEYS_BACKEND=empty` (default) | shipped |
| `DaemonBackend` | `NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon`          | PR-C (calls agentkeys-daemon HTTP surface) |

No mock data lives anywhere in the codebase. To see populated views, run a real daemon and switch the backend env var.

## Demo Act 3 (revocation)

Open a device → "revoke device" → K11 WebAuthn modal renders the intent context with mock Touch ID scan → on confirm, actor flips to revoked and a `device.revoked` event appears at the top of the audit feed within ~200ms.

## Stack

- Next.js 14 (App Router)
- React 18
- TypeScript
- Plain CSS (no Tailwind — the design uses hairline-precise raw CSS variables)
- IBM Plex Mono + Serif via Google Fonts

No backend in this project — the UI is a thin client. Mock data is inlined for the M1 demo; M2 wires to the broker session JWT + audit-service SSE feed (per [issue #109](https://github.com/litentry/agentKeys/issues/109)).

Port `3113` matches the canonical web-UI port in [`docs/arch.md`](../../docs/arch.md) §22c.1 (the bundled-app surface). When this UI is later folded into the Rust daemon's `agentkeys web` subcommand, the URL stays identical.

## Develop

```sh
cd apps/parent-control
npm install
npm run dev          # http://localhost:3113
npm run build        # production build
npm run typecheck    # tsc --noEmit
```

## Deploy (M1)

Vercel. Point the project at `apps/parent-control` and the build settles itself.

## File layout

```
apps/parent-control/
  app/
    layout.tsx                  · root layout + IBM Plex fonts
    page.tsx                    · server entry; mounts the SPA
    globals.css                 · iii.dev styles (ported from styles.css)
    _components/
      types.ts                  · Actor, AuditEvent, Worker
      data.ts                   · INITIAL_ACTORS, INITIAL_EVENTS, SIM_EVENTS
      shared.tsx                · Chip, Dot, Panel, Modal, WebAuthnModal, …
      pages.tsx                 · Actors, ActorDetail, Audit, Anchor
      workers.tsx               · Workers page + worker detail
      logos.tsx                 · 6 Bedlington variants + LogoPage
      App.tsx                   · main App (routing, SSE sim, revoke flows)
```
