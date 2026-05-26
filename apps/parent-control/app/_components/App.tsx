'use client';

import { useEffect, useRef, useState } from 'react';
import { INITIAL_ACTORS, INITIAL_EVENTS, SIM_EVENTS } from './data';
import { LogoPage } from './logos';
import { ActorDetailPage, ActorsPage, AnchorPage, AuditPage } from './pages';
import { Modal, WebAuthnModal } from './shared';
import type { Actor, AuditEvent, PendingAction, Route } from './types';
import { WorkersPage } from './workers';

function nowTs(d: Date = new Date()) {
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
}

export function App() {
  const [actors, setActors] = useState<Actor[]>(INITIAL_ACTORS);
  const [events, setEvents] = useState<AuditEvent[]>(() => INITIAL_EVENTS.map((e) => ({ ...e })));
  const [route, setRoute] = useState<Route>({ page: 'actors', actorId: null });
  const [sideOpen, setSideOpen] = useState(false);
  const [paused, setPaused] = useState(false);
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [eventDetail, setEventDetail] = useState<AuditEvent | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  // ─── Sim: incoming SSE events ──────────────────────────────────
  const simIdx = useRef(0);
  useEffect(() => {
    if (paused) return;
    const tick = () => {
      simIdx.current = (simIdx.current + 1) % SIM_EVENTS.length;
      const template = SIM_EVENTS[simIdx.current];
      const newEvent: AuditEvent = {
        ...template,
        id: `e-live-${Date.now()}`,
        ts: nowTs(),
        _isNew: true,
      };
      setEvents((prev) => [newEvent, ...prev].slice(0, 80));
      setTimeout(() => {
        setEvents((prev) => prev.map((e) => (e.id === newEvent.id ? { ...e, _isNew: false } : e)));
      }, 1500);
    };
    const intv = setInterval(tick, 4200);
    return () => clearInterval(intv);
  }, [paused]);

  const updateActor = (id: string, patch: Partial<Actor>) => {
    setActors((prev) => prev.map((a) => (a.id === id ? { ...a, ...patch } : a)));
    showToast('scope updated · K11 assertion queued for next save');
  };

  const showToast = (msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 2600);
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

  const confirmAction = () => {
    const action = pendingAction;
    setPendingAction(null);
    if (!action) return;

    const ts = nowTs();

    if (action.kind === 'revoke-device') {
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
    }

    if (action.kind === 'revoke-scope') {
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
  };

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

  const sectionAttr = (['audit', 'anchor', 'workers', 'logo'] as const).includes(route.page as never)
    ? route.page
    : undefined;

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
            chain · litentry-parachain · block 4 821 022
          </span>
          <span className="who">
            <span className="who-text">Sara · O_master · iPhone 17 Pro</span>
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
          <span className="count">5</span>
        </button>

        <div className="nav-section">brand</div>
        <button
          className={`nav-item ${route.page === 'logo' ? 'active' : ''}`}
          onClick={() => go('logo')}
        >
          <span className="marker">[◐]</span> logo
        </button>

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

        <div className="nav-section">session</div>
        <div
          style={{
            padding: '6px 22px',
            fontSize: 11,
            color: 'var(--ink-faint)',
            lineHeight: 1.7,
          }}
        >
          K6 · session JWT
          <br />
          ttl 04h 47m
          <br />
          K11 · iOS SE · ok
        </div>
      </aside>

      <main className="app-main" data-section={sectionAttr}>
        {route.page === 'actors' && (
          <ActorsPage actors={actors} onPick={(id) => go('detail', id)} />
        )}
        {route.page === 'detail' && currentActor && (
          <ActorDetailPage
            actor={currentActor}
            onUpdate={updateActor}
            onBack={() => go('actors')}
            onRevoke={handleRevokeDevice}
            onRevokeScope={handleRevokeScope}
            recentEvents={events}
          />
        )}
        {route.page === 'audit' && (
          <AuditPage
            events={events}
            onPick={setEventDetail}
            paused={paused}
            onPause={() => setPaused((p) => !p)}
          />
        )}
        {route.page === 'anchor' && <AnchorPage />}
        {route.page === 'workers' && (
          <WorkersPage actors={actors} onPickActor={(id) => go('detail', id)} />
        )}
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
            <dt>cap-token</dt>
            <dd className="mono">cap_{eventDetail.id.slice(-6)}…3f01</dd>
            <dt>K10 signer</dt>
            <dd className="mono">
              {eventDetail.actor === 'Sara (master)'
                ? 'D_pub_master_iphone'
                : 'D_pub_' + eventDetail.actor.toLowerCase().replace(/[^a-z]/g, '')}
              …
            </dd>
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
