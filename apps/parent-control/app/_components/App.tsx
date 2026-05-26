'use client';

import { useCallback, useEffect, useState } from 'react';
import { useClient, useConnectionStatus } from '@/lib/ClientProvider';
import type { CapToken } from '@/lib/client/types';
import { LogoPage } from './logos';
import { OnboardingPage } from './onboarding';
import { ActorDetailPage, ActorsPage, AnchorPage, AuditPage } from './pages';
import { Modal, PageHead, Panel, WebAuthnModal } from './shared';
import type { Actor, AuditEvent, PendingAction, Route } from './types';
import { WorkersPage } from './workers';

function nowTs(d: Date = new Date()) {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
}

export function App() {
  const client = useClient();
  const status = useConnectionStatus();

  const [actors, setActors] = useState<Actor[]>([]);
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [capTokens, setCapTokens] = useState<Record<string, CapToken[]>>({});
  const [route, setRoute] = useState<Route>({ page: 'actors', actorId: null });
  const [sideOpen, setSideOpen] = useState(false);
  const [paused, setPaused] = useState(false);
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [eventDetail, setEventDetail] = useState<AuditEvent | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  // ─── Initial fetch ─────────────────────────────────────────────
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [actorsResult, eventsResult] = await Promise.all([
        client.listActors(),
        client.listRecentAuditEvents({ limit: 50 }),
      ]);
      if (cancelled) return;
      if (actorsResult.ok) setActors(actorsResult.data);
      if (eventsResult.ok) setEvents(eventsResult.data);
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  // ─── Cap-token fetch on actor detail ───────────────────────────
  useEffect(() => {
    if (route.page !== 'detail' || !route.actorId) return;
    const actorId = route.actorId;
    if (capTokens[actorId]) return;
    let cancelled = false;
    (async () => {
      const r = await client.listCapTokens(actorId);
      if (cancelled || !r.ok) return;
      setCapTokens((prev) => ({ ...prev, [actorId]: r.data }));
    })();
    return () => {
      cancelled = true;
    };
  }, [route, client, capTokens]);

  // ─── SSE subscription ──────────────────────────────────────────
  useEffect(() => {
    if (paused) return;
    const unsub = client.streamAudit(
      (incoming) => {
        const tagged: AuditEvent = { ...incoming, _isNew: true };
        setEvents((prev) => [tagged, ...prev].slice(0, 80));
        setTimeout(() => {
          setEvents((prev) =>
            prev.map((e) => (e.id === tagged.id ? { ...e, _isNew: false } : e)),
          );
        }, 1500);
      },
      () => {
        /* status changes propagate via context; no-op here */
      },
    );
    return unsub;
  }, [client, paused]);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 2600);
  }, []);

  const updateActor = useCallback(
    async (id: string, patch: Partial<Actor>) => {
      const previous = actors.find((a) => a.id === id);
      if (!previous) return;
      setActors((prev) => prev.map((a) => (a.id === id ? { ...a, ...patch } : a)));
      if (patch.scope) {
        const changedNs = Object.keys(patch.scope).find(
          (k) => previous.scope?.[k as keyof typeof previous.scope] !== patch.scope![k as keyof typeof patch.scope],
        );
        if (changedNs) {
          const ns = changedNs as keyof typeof patch.scope;
          const r = await client.updateScope(id, ns, patch.scope[ns]);
          if (!r.ok) {
            showToast(`scope update rejected · ${r.status.reason}`);
            setActors((prev) => prev.map((a) => (a.id === id ? previous : a)));
            return;
          }
          showToast('scope updated · K11 assertion queued for next save');
          return;
        }
      }
      if (patch.paymentCap) {
        const r = await client.updatePaymentCap(
          id,
          patch.paymentCap.perTx,
          patch.paymentCap.daily,
        );
        if (!r.ok) {
          showToast(`payment cap rejected · ${r.status.reason}`);
          setActors((prev) => prev.map((a) => (a.id === id ? previous : a)));
          return;
        }
        showToast('payment cap updated · K11 assertion queued for next save');
      }
    },
    [actors, client, showToast],
  );

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

  const handleRevokeScope = (actor: Actor, capName: string) => {
    setPendingAction({
      kind: 'revoke-scope',
      actor,
      capName,
      intent: {
        text: 'Revoke cap-token',
        fields: [
          ['actor', actor.label],
          ['cap', capName],
          ['actor_omni', actor.omni.slice(0, 30) + '…'],
          ['mutation', 'broker.revoke_cap + chain commit'],
          ['effect', 'next call returns 403 · ≤200ms'],
        ],
      },
    });
  };

  const confirmAction = useCallback(async () => {
    const action = pendingAction;
    setPendingAction(null);
    if (!action) return;

    const ts = nowTs();

    if (action.kind === 'revoke-device') {
      const r = await client.revokeDevice(action.actor.id, action.intent);
      if (!r.ok) {
        showToast(`revoke rejected · ${r.status.reason}`);
        return;
      }
      setActors((prev) =>
        prev.map((a) =>
          a.id === action.actor.id
            ? { ...a, status: 'bad', lastActive: 'revoked', label: a.label + ' (revoked)' }
            : a,
        ),
      );
      setEvents((prev) => [
        {
          id: `e-live-${Date.now()}`,
          ts,
          actorId: 'master',
          actor: 'Sara (master)',
          kind: 'device.revoked',
          detail: `${action.actor.label} · ${action.actor.devicePubkey.slice(0, 18)}… · K11 assertion ok`,
          chip: 'revoke',
          sev: 'bad',
          _isNew: true,
        },
        ...prev,
      ]);
      showToast(`${action.actor.label} revoked. SSE drop event broadcast.`);
      setRoute({ page: 'audit', actorId: null });
      return;
    }

    if (action.kind === 'revoke-scope') {
      const r = await client.revokeCap(action.actor.id, action.capName, action.intent);
      if (!r.ok) {
        showToast(`revoke rejected · ${r.status.reason}`);
        return;
      }
      setEvents((prev) => [
        {
          id: `e-live-${Date.now()}`,
          ts,
          actorId: 'master',
          actor: 'Sara (master)',
          kind: 'cap.revoked',
          detail: `${action.actor.label} · ${action.capName} · K11 ok`,
          chip: 'revoke',
          sev: 'bad',
          _isNew: true,
        },
        ...prev,
      ]);
      showToast(`${action.capName} revoked for ${action.actor.label}.`);
    }
  }, [client, pendingAction, showToast]);

  const go = (page: Route['page'], actorId: string | null = null) => {
    if (page === 'detail' && actorId) {
      setRoute({ page: 'detail', actorId });
    } else {
      setRoute({ page, actorId: null } as Route);
    }
    setSideOpen(false);
    if (typeof window !== 'undefined') {
      window.scrollTo({ top: 0, behavior: 'instant' });
    }
  };

  const currentActor = route.actorId ? actors.find((a) => a.id === route.actorId) : null;
  const sectionAttr = (['audit', 'anchor', 'workers', 'logo', 'onboarding'] as const).includes(
    route.page as never,
  )
    ? route.page
    : undefined;

  const connectionLabel =
    status.kind === 'connected'
      ? `${status.via} · ${status.endpoint}`
      : status.reason === 'no-backend-configured'
        ? 'backend not configured'
        : status.reason === 'unauthorized'
          ? 'unauthorized'
          : 'unreachable';

  return (
    <div className="app">
      <header className="app-head">
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <button className="hamb" onClick={() => setSideOpen((o) => !o)} aria-label="menu">
            {sideOpen ? '✕' : '≡'}
          </button>
          <div className="brand">
            <span className="mark">agentKeys</span>
            <span className="sub">parent control · m1</span>
          </div>
        </div>
        <div className="head-right">
          <span style={{ fontSize: 10, letterSpacing: '0.08em', textTransform: 'uppercase' }}>
            {connectionLabel}
          </span>
          <span className="who">
            <span className="who-text">
              {actors.find((a) => a.role === 'master')?.label ?? 'no master enrolled'}
            </span>
          </span>
        </div>
      </header>

      <aside className={`app-side ${sideOpen ? 'open' : ''}`}>
        <div className="nav-section">control</div>
        <button
          className={`nav-item ${route.page === 'actors' ? 'active' : ''}`}
          onClick={() => go('actors')}
        >
          <span className="marker">[•]</span> actors
          <span className="count">{actors.length}</span>
        </button>
        <button
          className={`nav-item ${route.page === 'audit' ? 'active' : ''}`}
          onClick={() => go('audit')}
        >
          <span className="marker">{paused ? '[ ]' : '[~]'}</span> audit feed
          <span className="count">{events.length}</span>
        </button>
        <button
          className={`nav-item ${route.page === 'anchor' ? 'active' : ''}`}
          onClick={() => go('anchor')}
        >
          <span className="marker">[↗]</span> anchor status
        </button>
        <button
          className={`nav-item ${route.page === 'workers' ? 'active' : ''}`}
          onClick={() => go('workers')}
        >
          <span className="marker">[#]</span> workers
        </button>

        <div className="nav-section">onboarding</div>
        <button
          className={`nav-item ${route.page === 'onboarding' ? 'active' : ''}`}
          onClick={() => go('onboarding')}
        >
          <span className="marker">[+]</span> add device
        </button>

        <div className="nav-section">brand</div>
        <button
          className={`nav-item ${route.page === 'logo' ? 'active' : ''}`}
          onClick={() => go('logo')}
        >
          <span className="marker">[◐]</span> logo
        </button>

        {actors.length > 0 && (
          <>
            <div className="nav-section">actor tree</div>
            {actors.map((a) => (
              <button
                key={a.id}
                className={`nav-item ${route.page === 'detail' && route.actorId === a.id ? 'active' : ''}`}
                onClick={() => go('detail', a.id)}
                style={{ paddingLeft: a.role === 'agent' ? 36 : 22 }}
              >
                <span className="marker" style={{ fontSize: 10 }}>
                  {a.role === 'master' ? '/' : '└'}
                </span>
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {a.label.replace(' (revoked)', '')}
                </span>
                {a.status === 'bad' && (
                  <span className="count" style={{ color: 'var(--danger)' }}>
                    rvk
                  </span>
                )}
                {a.status === 'warn' && (
                  <span className="count" style={{ color: 'var(--accent)' }}>
                    !
                  </span>
                )}
              </button>
            ))}
          </>
        )}

        <div className="nav-section">session</div>
        <div
          style={{
            padding: '6px 22px',
            fontSize: 11,
            color: 'var(--ink-faint)',
            lineHeight: 1.7,
          }}
        >
          {status.kind === 'connected' ? (
            <>
              K6 · session JWT
              <br />
              via {status.via}
            </>
          ) : (
            <>no session · daemon offline</>
          )}
        </div>
      </aside>

      <main className="app-main" data-section={sectionAttr}>
        {route.page === 'actors' && <ActorsPage actors={actors} status={status} onPick={(id) => go('detail', id)} />}
        {route.page === 'detail' && currentActor && (
          <ActorDetailPage
            actor={currentActor}
            onUpdate={updateActor}
            onBack={() => go('actors')}
            onRevoke={handleRevokeDevice}
            onRevokeScope={handleRevokeScope}
            recentEvents={events}
            capTokens={capTokens[currentActor.id] ?? []}
          />
        )}
        {route.page === 'audit' && (
          <AuditPage
            events={events}
            status={status}
            onPick={setEventDetail}
            paused={paused}
            onPause={() => setPaused((p) => !p)}
          />
        )}
        {route.page === 'anchor' && <AnchorPage />}
        {route.page === 'workers' && (
          <WorkersPage status={status} onPickActor={(id) => go('detail', id)} />
        )}
        {route.page === 'onboarding' && (
          <OnboardingPage onClose={() => go('actors')} />
        )}
        {route.page === 'onboarding-mobile' && <MobileStub onBack={() => go('onboarding')} />}
        {route.page === 'logo' && <LogoPage />}
      </main>

      {pendingAction && (
        <WebAuthnModal
          intent={pendingAction.intent}
          onConfirm={confirmAction}
          onCancel={() => setPendingAction(null)}
        />
      )}

      {eventDetail && (
        <Modal
          title={`event · ${eventDetail.id}`}
          onClose={() => setEventDetail(null)}
          footer={
            <>
              <button className="btn" onClick={() => setEventDetail(null)}>
                close
              </button>
              <a
                className="btn primary"
                href="#"
                onClick={(e) => {
                  e.preventDefault();
                  setEventDetail(null);
                }}
              >
                view on chain ↗
              </a>
            </>
          }
        >
          <dl className="kvs">
            <dt>timestamp</dt>
            <dd className="mono">{eventDetail.ts}</dd>
            <dt>actor</dt>
            <dd>{eventDetail.actor}</dd>
            <dt>kind</dt>
            <dd className="mono">{eventDetail.kind}</dd>
            <dt>detail</dt>
            <dd>{eventDetail.detail}</dd>
            <dt>worker</dt>
            <dd className="mono">{eventDetail.chip}-service</dd>
            <dt>tier</dt>
            <dd>tier-1 (sse) · pending tier-2 anchor</dd>
            <dt>event id</dt>
            <dd className="mono">{eventDetail.id}</dd>
          </dl>
        </Modal>
      )}

      {toast && (
        <div
          style={{
            position: 'fixed',
            bottom: 24,
            left: '50%',
            transform: 'translateX(-50%)',
            background: 'var(--ink)',
            color: 'var(--bg)',
            padding: '10px 18px',
            fontSize: 12,
            border: '1px solid var(--ink)',
            zIndex: 200,
            animation: 'pop 0.22s cubic-bezier(.2,.8,.2,1)',
          }}
        >
          {toast}
        </div>
      )}
    </div>
  );
}

function MobileStub({ onBack }: { onBack: () => void }) {
  const fakeQR = Array.from({ length: 21 * 21 }, (_, i) => {
    const x = i % 21;
    const y = Math.floor(i / 21);
    const corner =
      (x < 7 && y < 7) || (x >= 14 && y < 7) || (x < 7 && y >= 14);
    const cornerInner =
      ((x >= 2 && x < 5 && y >= 2 && y < 5)) ||
      ((x >= 16 && x < 19 && y >= 2 && y < 5)) ||
      ((x >= 2 && x < 5 && y >= 16 && y < 19));
    const cornerFrame =
      (x === 0 || x === 6 || y === 0 || y === 6) && x < 7 && y < 7;
    const cornerFrameTR =
      (x === 14 || x === 20 || y === 0 || y === 6) && x >= 14 && y < 7;
    const cornerFrameBL =
      (x === 0 || x === 6 || y === 14 || y === 20) && x < 7 && y >= 14;
    if (corner) return cornerInner || cornerFrame || cornerFrameTR || cornerFrameBL ? 1 : 0;
    return Math.abs(((x * 31) ^ (y * 17)) % 2);
  });

  return (
    <>
      <PageHead
        crumb={
          <>
            <a onClick={onBack} style={{ cursor: 'pointer' }}>
              onboarding
            </a>{' '}
            <span className="muted">/</span> mobile
          </>
        }
        title={
          <>
            <span className="muted serif">/</span> mobile · second master
          </>
        }
        desc="Stub. Real cross-device WebAuthn (FIDO CTAP 2.2 hybrid transport) ships in M5 after the vendor pilot signs. This page exists to show what the operator will see, not to perform the ceremony."
        actions={
          <button className="btn" onClick={onBack}>
            ← back
          </button>
        }
      />

      <div className="banner warn">
        <span className="lbl">stub</span>
        <span>
          arch.md §10.5 1-of-2 recovery is a real architectural commitment. This page is a stub today — no QR
          scanning, no companion-daemon negotiation. Tracked for M5 (issue TBD).
        </span>
      </div>

      <Panel title="── pair a second master device">
        <div style={{ display: 'flex', gap: 28, alignItems: 'center', padding: '12px 0' }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(21, 8px)',
              gridTemplateRows: 'repeat(21, 8px)',
              padding: 8,
              background: 'var(--bg)',
              border: '1px solid var(--rule)',
            }}
            aria-label="QR code preview (stub)"
          >
            {fakeQR.map((bit, i) => (
              <div
                key={i}
                style={{ background: bit ? 'var(--ink)' : 'var(--bg)' }}
              />
            ))}
          </div>
          <div style={{ fontSize: 12, lineHeight: 1.7 }}>
            <div className="serif" style={{ fontSize: 18, fontStyle: 'italic', marginBottom: 4 }}>
              scan with iPad or Android
            </div>
            <div className="muted" style={{ marginBottom: 12 }}>
              When the real flow ships, this QR encodes the cross-device WebAuthn hybrid-transport
              challenge. The phone&apos;s platform authenticator generates K11, signs the master-binding
              ceremony, and registers as the second device on SidecarRegistry.
            </div>
            <div className="muted" style={{ fontSize: 11 }}>
              role on chain · <span className="mono">CAP_MINT | RECOVERY</span> (no SCOPE_MGMT)
              <br />
              quorum · 1-of-2 (operator-configurable per arch.md §10.6)
              <br />
              ceremony · v2-stage2-demo.sh steps 4-6
            </div>
          </div>
        </div>
      </Panel>

      <Panel title="── what the companion daemon does (preview)">
        <ol style={{ paddingLeft: 18, lineHeight: 1.9, fontSize: 12.5 }}>
          <li>operator scans QR on second device → cross-device WebAuthn opens</li>
          <li>phone generates its own K10 in the device&apos;s Secure Enclave / StrongBox</li>
          <li>phone runs WebAuthn ceremony → produces local K11 (sealed in TEE)</li>
          <li>existing master signs `register_companion_master(D_pub_phone, K11_credId_phone)` on-chain</li>
          <li>SidecarRegistry adds the phone as a second master with `CAP_MINT | RECOVERY` roles</li>
          <li>recoveryThreshold automatically bumps to 2 once two K11s are registered</li>
        </ol>
      </Panel>
    </>
  );
}
