'use client';

import { useEffect, useRef, useState } from 'react';
import {
  CHAIN_PROFILE,
  INCOMING_PAIRING,
  INITIAL_ACTORS,
  INITIAL_EVENTS,
  ONCHAIN_KINDS,
  PRESERVED_MEMORY,
  SIM_EVENTS,
  contractFor,
  decodeCalldata,
  txHash,
} from '@/lib/demoData';
import { NAMESPACES } from '@/lib/constants';
import { CeremonyRunner, OnboardingScreen } from './ceremony';
import { ActorDetail, ActorsList, AuditFeed } from './dashboard';
import { LogoPage } from './logos';
import { MemoryPage } from './memory';
import { PairingPage } from './pairing';
import { Modal, WebAuthnModal } from './shared';
import { PAIRING_STEPS } from '@/lib/demoData';
import type { Actor, AuditEvent, Namespace, PairingRequest, PreservedMemory, ScopeBits } from './types';

type Page = 'actors' | 'detail' | 'memory' | 'pairing' | 'audit' | 'chain' | 'logo';

type PendingAction =
  | { kind: 'revoke-device'; actor: Actor; intent: Intent }
  | { kind: 'pair-accept'; req: PairingRequest; intent: Intent };
interface Intent { text: string; fields: [string, string][] }

const nowTs = () => {
  const n = new Date();
  return `${String(n.getHours()).padStart(2, '0')}:${String(n.getMinutes()).padStart(2, '0')}:${String(n.getSeconds()).padStart(2, '0')}`;
};

export function App() {
  const [actors, setActors] = useState<Actor[]>(INITIAL_ACTORS);
  const [events, setEvents] = useState<AuditEvent[]>(() => INITIAL_EVENTS.map((e) => ({ ...e })));
  const [page, setPage] = useState<Page>('actors');
  const [actorId, setActorId] = useState<string | null>(null);
  const [sideOpen, setSideOpen] = useState(false);
  const [paused, setPaused] = useState(false);
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [eventDetail, setEventDetail] = useState<AuditEvent | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const [onboarded, setOnboarded] = useState(false);
  const [memories, setMemories] = useState<PreservedMemory[]>([]);
  const [planting, setPlanting] = useState(false);
  const [pairingRequests, setPairingRequests] = useState<PairingRequest[]>([]);
  const [pairingCeremony, setPairingCeremony] = useState<PairingRequest | null>(null);
  const [justPaired, setJustPaired] = useState<string | null>(null);
  const [memoryView, setMemoryView] = useState<PreservedMemory | null>(null);

  useEffect(() => {
    try { setOnboarded(localStorage.getItem('ak_onboarded') === '1'); } catch {}
  }, []);

  const showToast = (msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 2600);
  };

  const pushEvent = (ev: Omit<AuditEvent, 'id' | 'ts' | '_isNew'>) => {
    const e: AuditEvent = { id: `e-live-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`, ts: nowTs(), _isNew: true, ...ev };
    setEvents((prev) => [e, ...prev].slice(0, 90));
    setTimeout(() => setEvents((prev) => prev.map((x) => (x.id === e.id ? { ...x, _isNew: false } : x))), 1500);
  };

  // Workflow 3-4: a pairing request arrives ~9s after onboarding (the Hermes agent on another machine).
  useEffect(() => {
    if (!onboarded || justPaired) return;
    const t = setTimeout(() => setPairingRequests((prev) => (prev.length ? prev : [INCOMING_PAIRING])), 9000);
    return () => clearTimeout(t);
  }, [onboarded, justPaired]);

  // SSE sim — live audit feed.
  const simIdx = useRef(0);
  useEffect(() => {
    if (paused) return;
    const tick = () => {
      simIdx.current = (simIdx.current + 1) % SIM_EVENTS.length;
      const template = SIM_EVENTS[simIdx.current];
      const e: AuditEvent = { ...template, id: `e-live-${Date.now()}`, ts: nowTs(), _isNew: true };
      setEvents((prev) => [e, ...prev].slice(0, 80));
      setTimeout(() => setEvents((prev) => prev.map((x) => (x.id === e.id ? { ...x, _isNew: false } : x))), 1500);
    };
    const intv = setInterval(tick, 4200);
    return () => clearInterval(intv);
  }, [paused]);

  const go = (p: Page, id: string | null = null) => {
    setPage(p);
    setActorId(id);
    setSideOpen(false);
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'instant' });
  };

  const updateActor = (id: string, patch: Partial<Actor>) => {
    setActors((prev) => prev.map((a) => (a.id === id ? { ...a, ...patch } : a)));
    showToast('scope updated · K11 assertion queued for next save');
  };

  // ─── Memory: plant preserved memory (idempotent / dedup) ───────
  const plantMemory = () => {
    if (memories.length > 0) return; // dedup guard — already planted
    setPlanting(true);
  };
  const plantDone = () => {
    setPlanting(false);
    setMemories(PRESERVED_MEMORY);
    pushEvent({
      actorId: 'master', actor: 'Sara (master)', kind: 'memory.write',
      detail: `planted preserved memory · ${PRESERVED_MEMORY.length} entries · 0 duplicates`, chip: 'memory', sev: 'ok',
    });
    showToast('Preserved memory planted · plant action now disabled.');
  };

  // ─── Pairing: accept → K11 → ceremony → bind ───────────────────
  const acceptPairing = (req: PairingRequest) => {
    setPendingAction({
      kind: 'pair-accept',
      req,
      intent: {
        text: `Pair agent · ${req.agent}`,
        fields: [
          ['new actor', `O_master${req.derivation}`],
          ['device pubkey', req.dpub],
          ['pair-code', req.pairCode],
          ['grant', req.requested.map((p) => p.cap).join(' · ')],
          ['mutation', 'SidecarRegistry.registerDevice + setScope'],
        ],
      },
    });
  };
  const declinePairing = (id: string) => {
    setPairingRequests((prev) => prev.filter((r) => r.id !== id));
    pushEvent({ actorId: 'master', actor: 'Sara (master)', kind: 'audit.append', detail: 'pairing request declined · hermes', chip: 'audit', sev: 'ok' });
    showToast('Pairing request declined.');
  };
  const refreshPairing = () => {
    if (justPaired) { showToast('No new requests.'); return; }
    setPairingRequests((prev) => (prev.length ? prev : [INCOMING_PAIRING]));
    showToast('Polled rendezvous · 1 request found.');
  };

  const handleRevokeDevice = (actor: Actor) => {
    setPendingAction({
      kind: 'revoke-device',
      actor,
      intent: {
        text: `Revoke device · ${actor.label}`,
        fields: [
          ['actor_omni', actor.omni],
          ['device_pubkey', actor.devicePubkey.slice(0, 22) + '…'],
          ['mutation', 'SidecarRegistry.revoke_device'],
          ['propagation', 'SSE drop + cache zero'],
          ['scope effect', 'all caps invalidated · ttl 0s'],
        ],
      },
    });
  };

  const confirmAction = () => {
    const action = pendingAction;
    setPendingAction(null);
    if (!action) return;
    if (action.kind === 'pair-accept') {
      setPairingRequests((prev) => prev.filter((r) => r.id !== action.req.id));
      setPairingCeremony(action.req);
    }
    if (action.kind === 'revoke-device') {
      setActors((prev) => prev.map((a) => (a.id === action.actor.id ? { ...a, status: 'bad', lastActive: 'revoked', label: a.label + ' (revoked)' } : a)));
      pushEvent({ actorId: 'master', actor: 'Sara (master)', kind: 'device.revoked', detail: `${action.actor.label} · ${action.actor.devicePubkey.slice(0, 18)}… · K11 ok`, chip: 'revoke', sev: 'bad' });
      showToast(`${action.actor.label} revoked. SSE drop event broadcast.`);
      go('audit');
    }
  };

  // Workflow 7-8: pairing ceremony completes → new Hermes actor appears with granted scope.
  const finishPairingCeremony = () => {
    const req = pairingCeremony;
    setPairingCeremony(null);
    if (!req) return;
    const grantNs = {} as Record<Namespace, ScopeBits>;
    NAMESPACES.forEach((ns) => {
      const canR = req.requested.some((p) => p.cap.startsWith('memory:read') && p.ns.includes(ns));
      const canW = req.requested.some((p) => p.cap.startsWith('memory:write') && p.ns.includes(ns));
      grantNs[ns] = { read: canR || canW, write: canW };
    });
    const hermes: Actor = {
      id: 'agent-hermes', omni: 'O_master//hermes', omniHex: '0x3f9c…8e15', label: 'Hermes (research)',
      role: 'agent', parent: 'master', derivation: '//hermes', device: req.device, devicePubkey: req.dpub,
      lastActive: 'now', status: 'ok', vendor: req.vendor, k11: false, justPaired: true, scope: grantNs,
      paymentCap: { perTx: 0, daily: 0, currency: 'USDC' }, timeWindow: { start: '00:00', end: '24:00', tz: 'local' },
      services: ['memory', 'audit'],
    };
    setActors((prev) => (prev.find((a) => a.id === 'agent-hermes') ? prev : [...prev, hermes]));
    setJustPaired('Hermes');
    pushEvent({ actorId: 'master', actor: 'Sara (master)', kind: 'cap.pair', detail: 'O_master//hermes · tier=2 · D_pub_hermes · registerDevice', chip: 'broker', sev: 'ok' });
    pushEvent({ actorId: 'master', actor: 'Sara (master)', kind: 'scope.grant', detail: 'hermes · memory:rw personal,travel · audit:append', chip: 'broker', sev: 'ok' });
    pushEvent({ actorId: 'agent-hermes', actor: 'Hermes', kind: 'cap.mint', detail: 'memory:read scope=personal,travel ttl=900s', chip: 'broker', sev: 'ok' });
    pushEvent({ actorId: 'agent-hermes', actor: 'Hermes', kind: 'memory.read', detail: 'personal/profile.md · injected at session start', chip: 'memory', sev: 'ok' });
    showToast('Hermes paired · cap-tokens minted · session key handed off.');
    go('pairing');
  };

  const currentActor = actorId ? actors.find((a) => a.id === actorId) : null;
  const sectionAttr = (['audit', 'memory', 'pairing', 'chain', 'logo'] as string[]).includes(page) ? page : undefined;

  // ─── Onboarding gate (workflow 1) ──────────────────────────────
  if (!onboarded) {
    return (
      <OnboardingScreen
        onComplete={() => {
          try { localStorage.setItem('ak_onboarded', '1'); } catch {}
          setOnboarded(true);
          go('actors');
        }}
      />
    );
  }

  return (
    <div className="app">
      <header className="app-head">
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <button className="hamb" onClick={() => setSideOpen((o) => !o)} aria-label="menu">{sideOpen ? '✕' : '≡'}</button>
          <div className="brand">
            <span className="mark">agentKeys</span>
            <span className="sub">parent control · m1</span>
          </div>
        </div>
        <div className="head-right">
          <span style={{ fontSize: 10, letterSpacing: '0.08em', textTransform: 'uppercase' }}>chain · heima · block 4 821 022</span>
          <button
            className={`bell ${pairingRequests.length ? 'has-req' : ''}`}
            onClick={() => go('pairing')}
            aria-label="pairing requests"
            title={pairingRequests.length ? `${pairingRequests.length} pairing request` : 'no pending requests'}
          >
            ◉{pairingRequests.length > 0 && <span className="badge">{pairingRequests.length}</span>}
          </button>
          <span className="who"><span className="who-text">Sara · O_master · iPhone 17 Pro</span></span>
        </div>
      </header>

      <aside className={`app-side ${sideOpen ? 'open' : ''}`}>
        <div className="nav-section">control</div>
        <button className={`nav-item ${page === 'actors' ? 'active' : ''}`} onClick={() => go('actors')}>
          <span className="marker">[•]</span> actors<span className="count">{actors.length}</span>
        </button>
        <button className={`nav-item ${page === 'memory' ? 'active' : ''}`} onClick={() => go('memory')}>
          <span className="marker">[◇]</span> memory<span className="count">{memories.length || '∅'}</span>
        </button>
        <button className={`nav-item ${page === 'pairing' ? 'active' : ''}`} onClick={() => go('pairing')}>
          <span className="marker">[⇄]</span> pairing
          {pairingRequests.length > 0 && <span className="count" style={{ color: 'var(--accent)' }}>{pairingRequests.length}●</span>}
        </button>

        <div className="nav-section">telemetry</div>
        <button className={`nav-item ${page === 'audit' ? 'active' : ''}`} onClick={() => go('audit')}>
          <span className="marker">{paused ? '[ ]' : '[~]'}</span> audit feed<span className="count">{events.length}</span>
        </button>
        <button className={`nav-item ${page === 'chain' ? 'active' : ''}`} onClick={() => go('chain')}>
          <span className="marker">[⇔]</span> chain
        </button>

        <div className="nav-section">ceremonies</div>
        <button className="nav-item" onClick={() => { try { localStorage.removeItem('ak_onboarded'); } catch {} setOnboarded(false); }}>
          <span className="marker">[◆]</span> replay onboarding
        </button>

        <div className="nav-section">brand</div>
        <button className={`nav-item ${page === 'logo' ? 'active' : ''}`} onClick={() => go('logo')}>
          <span className="marker">[◐]</span> logo
        </button>

        <div className="nav-section">actor tree</div>
        {actors.map((a) => (
          <button
            key={a.id}
            className={`nav-item ${page === 'detail' && actorId === a.id ? 'active' : ''}`}
            onClick={() => go('detail', a.id)}
            style={{ paddingLeft: a.role === 'agent' ? 36 : 22 }}
          >
            <span className="marker" style={{ fontSize: 10 }}>{a.role === 'master' ? '/' : '└'}</span>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.label.replace(' (revoked)', '')}</span>
            {a.status === 'bad' && <span className="count" style={{ color: 'var(--danger)' }}>rvk</span>}
            {a.status === 'warn' && <span className="count" style={{ color: 'var(--accent)' }}>!</span>}
          </button>
        ))}

        <div className="nav-section">session</div>
        <div style={{ padding: '6px 22px', fontSize: 11, color: 'var(--ink-faint)', lineHeight: 1.7 }}>
          K6 · session JWT<br />ttl 04h 47m<br />K11 · iOS SE · ok
        </div>
      </aside>

      <main className="app-main" data-section={sectionAttr}>
        {page === 'actors' && <ActorsList actors={actors} onPick={(id) => go('detail', id)} />}
        {page === 'detail' && currentActor && (
          <ActorDetail actor={currentActor} onBack={() => go('actors')} onUpdate={updateActor} onRevoke={handleRevokeDevice} recentEvents={events} />
        )}
        {page === 'memory' && (
          <MemoryPage memories={memories} onPlant={plantMemory} planting={planting} onPlantDone={plantDone} onView={setMemoryView} />
        )}
        {page === 'pairing' && (
          <PairingPage requests={pairingRequests} actors={actors} onAccept={acceptPairing} onDecline={declinePairing} onRefresh={refreshPairing} justPaired={justPaired} onManage={(id) => go('detail', id)} />
        )}
        {page === 'audit' && <AuditFeed events={events} onPick={setEventDetail} paused={paused} onPause={() => setPaused((p) => !p)} />}
        {page === 'chain' && <ChainPage />}
        {page === 'logo' && <LogoPage />}
      </main>

      {pendingAction && (
        <WebAuthnModal intent={pendingAction.intent} onConfirm={confirmAction} onCancel={() => setPendingAction(null)} />
      )}

      {eventDetail && <EventDecodeModal event={eventDetail} onClose={() => setEventDetail(null)} />}

      {memoryView && (
        <Modal
          title={`memory · ${memoryView.ns}/${memoryView.title}`}
          onClose={() => setMemoryView(null)}
          footer={<button className="btn" onClick={() => setMemoryView(null)}>close</button>}
        >
          <dl className="kvs" style={{ marginBottom: 14 }}>
            <dt>path</dt><dd className="mono" style={{ fontSize: 11 }}>s3://…/bots/&lt;omni&gt;/{memoryView.ns}/{memoryView.key}.enc</dd>
            <dt>envelope</dt><dd className="mono">{memoryView.version} · AES-256-GCM · k3 v1</dd>
            <dt>bytes</dt><dd className="mono">{memoryView.bytes}</dd>
            <dt>updated</dt><dd>{memoryView.updated}</dd>
          </dl>
          <div style={{ fontSize: 10, letterSpacing: '0.1em', textTransform: 'uppercase', color: 'var(--ink-faint)', marginBottom: 6 }}>decrypted plaintext</div>
          <pre className="mem-body">{memoryView.body}</pre>
        </Modal>
      )}

      {pairingCeremony && (
        <div className="modal-bg">
          <div className="modal" style={{ maxWidth: 520 }} onClick={(e) => e.stopPropagation()}>
            <div className="modal-head"><span className="ttl">pairing ceremony · {pairingCeremony.agent}</span></div>
            <div className="modal-body">
              <div style={{ fontSize: 12, color: 'var(--ink-dim)', marginBottom: 14 }}>
                Binding <span className="mono">O_master{pairingCeremony.derivation}</span> under your master identity. Each on-chain step is a real Heima transaction.
              </div>
              <CeremonyRunner steps={PAIRING_STEPS} onDone={finishPairingCeremony} stepMs={680} />
            </div>
          </div>
        </div>
      )}

      {toast && (
        <div style={{ position: 'fixed', bottom: 24, left: '50%', transform: 'translateX(-50%)', background: 'var(--ink)', color: 'var(--bg)', padding: '10px 18px', fontSize: 12, border: '1px solid var(--ink)', zIndex: 200, animation: 'pop 0.22s cubic-bezier(.2,.8,.2,1)' }}>
          {toast}
        </div>
      )}
    </div>
  );
}

// ─── Step 9: decode the Heima transaction for an audit event ──────
function EventDecodeModal({ event, onClose }: { event: AuditEvent; onClose: () => void }) {
  const dec = decodeCalldata(event);
  const onchain = ONCHAIN_KINDS.has(event.kind);
  const tx = txHash(event.id + event.kind);
  const signer = event.actor === 'Sara (master)' ? 'D_pub_master_iphone' : 'D_pub_' + event.actor.toLowerCase().replace(/[^a-z]/g, '');
  const toContract = contractFor(event.kind);
  return (
    <Modal
      title={`event · ${event.kind}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>close</button>
          <a className="btn primary" href={`${CHAIN_PROFILE.explorer}/tx/${tx}`} target="_blank" rel="noreferrer">view on heima ↗</a>
        </>
      }
    >
      <dl className="kvs">
        <dt>timestamp</dt><dd className="mono">{event.ts}</dd>
        <dt>actor</dt><dd>{event.actor}</dd>
        <dt>kind</dt><dd className="mono">{event.kind}</dd>
        <dt>detail</dt><dd>{event.detail}</dd>
        <dt>worker</dt><dd className="mono">{event.chip}-service</dd>
        <dt>tier</dt><dd>{onchain ? 'tier-2 · committed on-chain' : 'tier-1 (sse) · folds into next 2-min anchor'}</dd>
        <dt>K10 signer</dt><dd className="mono">{signer}…</dd>
      </dl>

      <div className="hr-ascii" style={{ margin: '14px 0' }}>{'─'.repeat(220)}</div>

      <div style={{ fontSize: 10, letterSpacing: '0.1em', textTransform: 'uppercase', color: 'var(--ink-faint)', marginBottom: 8 }}>decoded heima transaction</div>
      <div className="tx-decode">
        <div className="tx-row"><span className="tx-k">tx_hash</span><span className="tx-v mono">{tx}</span></div>
        <div className="tx-row"><span className="tx-k">status</span><span className="tx-v">{onchain ? '✓ success · finalized' : 'tier-1 · not yet anchored'}</span></div>
        <div className="tx-row"><span className="tx-k">to</span><span className="tx-v mono">{toContract} · {CHAIN_PROFILE.contracts[0].addr.slice(0, 14)}…</span></div>
        <div className="tx-row"><span className="tx-k">selector</span><span className="tx-v mono">{dec.sel}</span></div>
        <div className="tx-row"><span className="tx-k">function</span><span className="tx-v mono">{dec.fn}</span></div>
        <div className="tx-row"><span className="tx-k">gas</span><span className="tx-v mono">{onchain ? '0.0009 HEI' : '— (off-chain)'}</span></div>
      </div>
      <div className="muted" style={{ fontSize: 10.5, marginTop: 10 }}>
        calldata decoded against verified ABI · {CHAIN_PROFILE.display} · <span className="mono">mock — real decode: GH #153</span>
      </div>
    </Modal>
  );
}

// ─── Lightweight chain page (deployed contracts + anchor countdown) ──
function ChainPage() {
  const p = CHAIN_PROFILE;
  const [picked, setPicked] = useState<(typeof p.contracts)[number] | null>(null);
  return (
    <>
      <div className="page-head">
        <div>
          <div className="crumb">chain · {p.name} · chain_id {p.chainId}</div>
          <h1><span className="muted serif">/</span> chain</h1>
          <div className="desc">Four stage-1 contracts deployed via Foundry. Tier-2 audit anchors a Merkle root here every 2 minutes.</div>
        </div>
      </div>
      <div className="stats">
        <div className="stat"><div className="v">{p.name}</div><div className="k">AGENTKEYS_CHAIN</div></div>
        <div className="stat"><div className="v">{p.chainId}</div><div className="k">chain id</div></div>
        <div className="stat"><div className="v">{p.block}</div><div className="k">latest block</div></div>
        <div className="stat"><div className="v">{p.contracts.length}</div><div className="k">contracts deployed</div></div>
      </div>
      <div className="panel">
        <div className="panel-head"><span>── deployed contracts · stage-1</span></div>
        <div className="panel-body flush">
          <table className="tab">
            <thead><tr><th>contract</th><th>address</th><th>deployed</th><th /></tr></thead>
            <tbody>
              {p.contracts.map((c) => (
                <tr key={c.name} className="clickable" onClick={() => setPicked(c)}>
                  <td><span style={{ fontWeight: 500 }}>{c.name}</span><div className="secondary">{c.purpose}</div></td>
                  <td className="mono" style={{ fontSize: 11 }}>{c.addr}</td>
                  <td className="muted mono">{c.deployedAt}</td>
                  <td className="right"><a href={`${p.explorer}/address/${c.addr}`} target="_blank" rel="noreferrer" style={{ fontSize: 11 }}>explorer ↗</a></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
      {picked && (
        <Modal
          title={`contract · ${picked.name}`}
          onClose={() => setPicked(null)}
          footer={<a className="btn primary" href={`${p.explorer}/address/${picked.addr}`} target="_blank" rel="noreferrer">view on {p.name} explorer ↗</a>}
        >
          <dl className="kvs">
            <dt>name</dt><dd>{picked.name}</dd>
            <dt>address</dt><dd className="mono" style={{ fontSize: 11 }}>{picked.addr}</dd>
            <dt>deployed at</dt><dd>{picked.deployedAt}</dd>
            <dt>purpose</dt><dd>{picked.purpose}</dd>
            <dt>verify</dt><dd className="mono" style={{ fontSize: 11 }}>cast code {picked.addr} --rpc-url {p.rpc}</dd>
          </dl>
        </Modal>
      )}
    </>
  );
}
