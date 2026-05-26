'use client';

import { useEffect, useState } from 'react';
import { NAMESPACES } from '@/lib/constants';
import type { CapToken, ConnectionStatus } from '@/lib/client/types';
import { ActorTree, Chip, Dot, EmptyState, Panel, PageHead, TripleToggle } from './shared';
import type { Actor, AuditEvent, ChipKind, Namespace, ScopeBits } from './types';

// ─── Page: Actors list ───────────────────────────────────────────
export function ActorsPage({
  actors,
  status,
  onPick,
}: {
  actors: Actor[];
  status: ConnectionStatus;
  onPick: (id: string) => void;
}) {
  const master = actors.find((a) => a.role === 'master');
  const agents = actors.filter((a) => a.role === 'agent');
  const active = agents.filter((a) => a.lastActive === 'now' || a.lastActive.endsWith('m ago')).length;
  const isEmpty = actors.length === 0;

  return (
    <>
      <PageHead
        crumb="actor tree · O_master"
        title={
          <>
            <span className="muted serif">/</span> actors
          </>
        }
        desc="Devices and agents bound to your actor tree. Each row is an HDKD child of your master — its own omni, its own scope, its own wallet."
      />

      {isEmpty ? (
        <EmptyState
          status={status}
          title="no actors enrolled"
          hint={
            <>
              Once a master device runs the v2-stage1 onboarding (identity + K11 + on-chain
              device-register), it appears here. See <span className="mono">harness/v2-stage1-demo.sh</span>.
            </>
          }
        />
      ) : (
        <>
          <div className="stats">
            <div className="stat">
              <div className="v">{agents.length}</div>
              <div className="k">agents bound</div>
              <div className="delta">live from daemon /v1/actors</div>
            </div>
            <div className="stat">
              <div className="v">{active}</div>
              <div className="k">active now</div>
              <div className="delta">SSE feed live · tier-1</div>
            </div>
            <div className="stat">
              <div className="v">—</div>
              <div className="k">events / 2-min batch</div>
              <div className="delta">populated by /v1/anchor/status</div>
            </div>
            <div className="stat">
              <div className="v">0</div>
              <div className="k">pending approvals</div>
              <div className="delta">no high-risk caps queued</div>
            </div>
          </div>

          <Panel title="── actor tree" flush>
            <div style={{ padding: '18px 22px' }}>
              <ActorTree actors={actors} onPick={onPick} />
            </div>
          </Panel>

          <Panel title="── devices · agents" flush>
            <table className="tab">
              <thead>
                <tr>
                  <th style={{ width: 32 }}></th>
                  <th>actor</th>
                  <th>derivation</th>
                  <th>vendor</th>
                  <th>device</th>
                  <th>last active</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {master && (
                  <tr className="clickable" onClick={() => onPick(master.id)}>
                    <td>
                      <Dot status="ok" />
                    </td>
                    <td>
                      <span className="serif" style={{ fontStyle: 'italic', fontSize: 14 }}>
                        {master.label}
                      </span>
                      <div className="secondary">
                        {master.omni} · {master.omniHex}
                      </div>
                    </td>
                    <td className="mono muted">/ (root)</td>
                    <td className="muted">self</td>
                    <td>{master.device}</td>
                    <td className="muted">now</td>
                    <td>
                      <Chip kind="default">master</Chip>
                    </td>
                  </tr>
                )}
                {agents.map((a) => (
                  <tr key={a.id} className="clickable" onClick={() => onPick(a.id)}>
                    <td>
                      <Dot status={a.status} pulse={a.lastActive.endsWith('m ago')} />
                    </td>
                    <td>
                      <span style={{ fontWeight: 500 }}>{a.label}</span>
                      <div className="secondary">{a.omni}</div>
                    </td>
                    <td className="mono">{a.derivation}</td>
                    <td>{a.vendor}</td>
                    <td>{a.device}</td>
                    <td className="muted">{a.lastActive}</td>
                    <td>
                      <button
                        className="btn sm"
                        onClick={(e) => {
                          e.stopPropagation();
                          onPick(a.id);
                        }}
                      >
                        manage →
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Panel>

          <div className="banner">
            <span className="lbl">tip</span>
            <span>
              One-tap revoke surfaces inside any actor row. Sensitive mutations (revoke, scope grant, payment cap) require K11
              biometric re-auth on this device.
            </span>
          </div>
        </>
      )}
    </>
  );
}

// ─── Page: Actor detail ──────────────────────────────────────────
export function ActorDetailPage({
  actor,
  onUpdate,
  onBack,
  onRevoke,
  onRevokeScope,
  recentEvents,
  capTokens,
}: {
  actor: Actor;
  onUpdate: (id: string, patch: Partial<Actor>) => void;
  onBack: () => void;
  onRevoke: (a: Actor) => void;
  onRevokeScope: (a: Actor, cap: string) => void;
  recentEvents: AuditEvent[];
  capTokens: CapToken[];
}) {
  if (actor.role === 'master') {
    return <MasterDetail actor={actor} onBack={onBack} />;
  }

  const events = recentEvents.filter((e) => e.actorId === actor.id).slice(0, 6);

  const setScope = (ns: Namespace, value: ScopeBits) => {
    onUpdate(actor.id, {
      scope: { ...(actor.scope as Record<Namespace, ScopeBits>), [ns]: value },
    });
  };

  const setPaymentCap = (key: 'perTx' | 'daily', value: number) => {
    onUpdate(actor.id, {
      paymentCap: { ...(actor.paymentCap as { perTx: number; daily: number; currency: string }), [key]: value },
    });
  };

  return (
    <>
      <PageHead
        crumb={
          <>
            <a onClick={onBack} style={{ cursor: 'pointer' }}>
              actors
            </a>{' '}
            <span className="muted">/</span> {actor.derivation}
          </>
        }
        title={
          <>
            <span className="muted serif">/</span> {actor.label}
          </>
        }
        desc={`Bound at ${actor.omni}. All scope, payment-cap, and time-window settings are master-mutations — each save triggers K11 + chain commit.`}
        actions={
          <>
            <button className="btn" onClick={onBack}>
              ← back
            </button>
            <button className="btn danger" onClick={() => onRevoke(actor)}>
              revoke device
            </button>
          </>
        }
      />

      <div className="banner warn" style={{ display: actor.status === 'warn' ? 'flex' : 'none' }}>
        <span className="lbl">warn</span>
        <span>
          {actor.label} attempted a payment outside its time-window 38m ago. Payments still gated; review the audit row →
        </span>
      </div>

      <Panel title="── binding">
        <dl className="kvs">
          <dt>actor_omni</dt>
          <dd className="mono">
            {actor.omni} <span className="muted">({actor.omniHex})</span>
          </dd>
          <dt>derivation</dt>
          <dd className="mono">
            {actor.derivation} <span className="muted">(hard / HDKD)</span>
          </dd>
          <dt>device pubkey</dt>
          <dd className="mono">
            {actor.devicePubkey} <span className="muted">· K10 secp256k1</span>
          </dd>
          <dt>vendor</dt>
          <dd>{actor.vendor}</dd>
          <dt>device</dt>
          <dd>{actor.device}</dd>
          <dt>K11 user-presence</dt>
          <dd>
            {actor.k11 ? 'enrolled (master device)' : <span className="muted">none · agents cannot hold K11</span>}
          </dd>
          <dt>last active</dt>
          <dd>{actor.lastActive}</dd>
          <dt>workers in scope</dt>
          <dd>
            {(actor.services ?? []).map((s) => (
              <span key={s} className="chip" style={{ marginRight: 6 }}>
                {s}
              </span>
            ))}
          </dd>
        </dl>
      </Panel>

      <Panel title="── scope · per-namespace">
        <div className="muted" style={{ fontSize: 11, marginBottom: 8 }}>
          Maps to ScopeContract[O_master][{actor.omni}] → {'{namespaces, ops}'}. Changes commit to chain via master K11.
        </div>
        {NAMESPACES.map((ns) => (
          <div key={ns} className="toggle-row">
            <div>
              <div className="lbl">{ns}</div>
              <div className="desc">
                {ns === 'personal' && 'private to you — diaries, photos, individual preferences'}
                {ns === 'family' && 'shared with family — schedules, lists, household state'}
                {ns === 'work' && 'work artifacts — credentials, repos, calendars'}
                {ns === 'travel' && 'travel context — locations, bookings, itineraries'}
              </div>
            </div>
            <TripleToggle
              value={actor.scope?.[ns] ?? { read: false, write: false }}
              onChange={(v) => setScope(ns, v)}
            />
          </div>
        ))}
      </Panel>

      <Panel title="── payment cap · class-C">
        <div className="muted" style={{ fontSize: 11, marginBottom: 10 }}>
          One-shot CAS-burn cap per arch §19. Above per-tx threshold, broker requires K11 assertion at mint time.
        </div>
        <div className="toggle-row">
          <div>
            <div className="lbl">per-transaction limit</div>
            <div className="desc">single payment cannot exceed this amount</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="number"
              value={actor.paymentCap?.perTx ?? 0}
              onChange={(e) => setPaymentCap('perTx', Number(e.target.value))}
              style={{
                width: 70,
                padding: '4px 8px',
                fontFamily: 'inherit',
                fontSize: 13,
                border: '1px solid var(--rule)',
                background: 'var(--bg)',
                color: 'var(--ink)',
                textAlign: 'right',
              }}
            />
            <span className="muted">{actor.paymentCap?.currency ?? 'USDC'}</span>
          </div>
        </div>
        <div className="toggle-row">
          <div>
            <div className="lbl">daily ceiling</div>
            <div className="desc">rolling 24h cumulative limit</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="number"
              value={actor.paymentCap?.daily ?? 0}
              onChange={(e) => setPaymentCap('daily', Number(e.target.value))}
              style={{
                width: 70,
                padding: '4px 8px',
                fontFamily: 'inherit',
                fontSize: 13,
                border: '1px solid var(--rule)',
                background: 'var(--bg)',
                color: 'var(--ink)',
                textAlign: 'right',
              }}
            />
            <span className="muted">{actor.paymentCap?.currency ?? 'USDC'}</span>
          </div>
        </div>
        {actor.timeWindow && (
          <div className="toggle-row">
            <div>
              <div className="lbl">time window</div>
              <div className="desc">payments outside this window are rejected at broker</div>
            </div>
            <div className="mono">
              {actor.timeWindow.start} <span className="muted">→</span> {actor.timeWindow.end}
            </div>
          </div>
        )}
      </Panel>

      <Panel title="── cap-tokens · live · per-actor revoke" flush>
        {capTokens.length === 0 ? (
          <div style={{ padding: 20 }} className="muted">
            no caps minted in this window. Daemon endpoint <span className="mono">GET /v1/actors/{actor.id}/caps</span>{' '}
            populates this table.
          </div>
        ) : (
          <table className="tab">
            <thead>
              <tr>
                <th>cap</th>
                <th>scope</th>
                <th>ttl</th>
                <th>minted</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {capTokens.map((c) => (
                <tr key={c.id}>
                  <td>
                    <span className="mono">{c.cap}</span>
                  </td>
                  <td className="muted">{c.scope}</td>
                  <td className="mono">{c.ttl}</td>
                  <td className="muted">{c.minted}</td>
                  <td className="right">
                    <button
                      className={`btn sm ${c.danger ? 'danger' : ''}`}
                      onClick={() => onRevokeScope(actor, c.cap)}
                    >
                      revoke
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>

      <Panel title={`── recent activity · ${actor.label}`} flush>
        {events.length === 0 ? (
          <div style={{ padding: 20 }} className="muted">
            no activity in this window.
          </div>
        ) : (
          events.map((e) => (
            <div key={e.id} className="feed-row">
              <span className="ts">{e.ts}</span>
              <span className="actor">{e.actor}</span>
              <span className="msg">
                <span style={{ fontWeight: 500 }}>{e.kind}</span>
                <span className="arg"> · {e.detail}</span>
              </span>
              <Chip kind={e.chip}>{e.chip}</Chip>
            </div>
          ))
        )}
      </Panel>
    </>
  );
}

function MasterDetail({ actor, onBack }: { actor: Actor; onBack: () => void }) {
  return (
    <>
      <PageHead
        crumb={
          <>
            <a onClick={onBack} style={{ cursor: 'pointer' }}>
              actors
            </a>{' '}
            <span className="muted">/</span> /
          </>
        }
        title={
          <>
            <span className="muted serif">/</span> {actor.label}
          </>
        }
        desc="Root of your HDKD actor tree. K11 user-presence credential lives on this device; all master mutations sign with it."
        actions={
          <button className="btn" onClick={onBack}>
            ← back
          </button>
        }
      />

      <Panel title="── master binding">
        <dl className="kvs">
          <dt>actor_omni</dt>
          <dd className="mono">
            {actor.omni} <span className="muted">({actor.omniHex})</span>
          </dd>
          <dt>device pubkey</dt>
          <dd className="mono">
            {actor.devicePubkey} <span className="muted">· K10 secp256k1 · SE</span>
          </dd>
          <dt>K11 (WebAuthn)</dt>
          <dd>
            {actor.k11 ? 'enrolled · platform authenticator' : 'not enrolled · run onboarding to enroll K11'}
          </dd>
          <dt>device</dt>
          <dd>{actor.device}</dd>
          <dt>last active</dt>
          <dd>{actor.lastActive}</dd>
        </dl>
      </Panel>
    </>
  );
}

// ─── Page: Audit feed ────────────────────────────────────────────
export function AuditPage({
  events,
  status,
  onPick,
  paused,
  onPause,
}: {
  events: AuditEvent[];
  status: ConnectionStatus;
  onPick: (e: AuditEvent) => void;
  paused: boolean;
  onPause: () => void;
}) {
  const [filter, setFilter] = useState<ChipKind | 'all'>('all');
  const filtered = filter === 'all' ? events : events.filter((e) => e.chip === filter);
  const filters: (ChipKind | 'all')[] = ['all', 'memory', 'creds', 'payment', 'audit', 'chain'];
  const isEmpty = events.length === 0;

  return (
    <>
      <PageHead
        crumb="tier-1 · sse · audit-service"
        title={
          <>
            <span className="muted serif">/</span> audit feed
          </>
        }
        desc="Real-time stream from the audit-service worker. Tier-1 is off-chain SSE (sub-200ms); tier-2 anchors a Merkle root on chain every 2 min."
        actions={
          <button className="btn sm" onClick={onPause}>
            {paused ? '▶ resume' : '❚❚ pause'}
          </button>
        }
      />

      <div className="banner">
        <span className="lbl">
          <Dot status={status.kind === 'connected' ? 'ok' : 'muted'} pulse={status.kind === 'connected' && !paused} />
          {status.kind === 'connected' ? (paused ? 'paused' : 'live') : 'offline'}
        </span>
        <span>
          {status.kind === 'connected'
            ? paused
              ? 'feed paused — incoming events queue at the broker SSE buffer.'
              : 'streaming from /v1/audit/stream · 1 connection · auto-reconnect on drop.'
            : 'daemon offline — no events to display.'}
        </span>
      </div>

      <Panel
        title="── stream · newest first"
        right={
          <div style={{ display: 'flex', gap: 6 }}>
            {filters.map((f) => (
              <button
                key={f}
                className={`btn sm ${filter === f ? 'primary' : ''}`}
                onClick={() => setFilter(f)}
              >
                {f}
              </button>
            ))}
          </div>
        }
        flush
      >
        {isEmpty ? (
          <div style={{ padding: 20 }}>
            <EmptyState
              status={status}
              title="no events"
              hint={
                <>
                  Once an agent runs <span className="mono">memory.read</span>,{' '}
                  <span className="mono">cred.fetch</span>, or <span className="mono">audit.append</span>, events stream
                  in here within ~200 ms.
                </>
              }
            />
          </div>
        ) : (
          <div className="feed">
            {filtered.map((e) => (
              <div
                key={e.id}
                className={`feed-row ${e._isNew ? 'new' : ''}`}
                onClick={() => onPick(e)}
              >
                <span className="ts">{e.ts}</span>
                <span className="actor">{e.actor}</span>
                <span className="msg">
                  <span style={{ fontWeight: 500 }}>{e.kind}</span>
                  <span className="arg"> · {e.detail}</span>
                </span>
                <Chip kind={e.chip}>{e.chip}</Chip>
              </div>
            ))}
            {filtered.length === 0 && (
              <div style={{ padding: 40, textAlign: 'center' }} className="muted">
                no events match this filter.
              </div>
            )}
          </div>
        )}
      </Panel>
    </>
  );
}

// ─── Page: Anchor status ─────────────────────────────────────────
export function AnchorPage() {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  let elapsed = 0;
  let next = 120;
  let pct = 0;
  if (now !== null) {
    elapsed = Math.floor((now / 1000) % 120);
    next = 120 - elapsed;
    pct = (elapsed / 120) * 100;
  }

  return (
    <>
      <PageHead
        crumb="tier-2 · on-chain · audit-anchor contract"
        title={
          <>
            <span className="muted serif">/</span> anchor status
          </>
        }
        desc="Every 2 minutes, the audit-service worker Merkleizes the tier-1 batch and submits a single extrinsic to the Litentry parachain."
      />

      <Panel title="── current batch · building">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'baseline',
            marginBottom: 14,
          }}
        >
          <div>
            <div
              className="muted"
              style={{ fontSize: 10, letterSpacing: '0.1em', textTransform: 'uppercase' }}
            >
              next anchor in
            </div>
            <div
              className="serif"
              style={{ fontSize: 36, fontStyle: 'italic', letterSpacing: '-0.02em', lineHeight: 1 }}
            >
              {String(Math.floor(next / 60)).padStart(2, '0')}:{String(next % 60).padStart(2, '0')}
            </div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div
              className="muted"
              style={{ fontSize: 10, letterSpacing: '0.1em', textTransform: 'uppercase' }}
            >
              events in batch
            </div>
            <div
              className="serif"
              style={{ fontSize: 36, fontStyle: 'italic', letterSpacing: '-0.02em', lineHeight: 1 }}
            >
              —
            </div>
          </div>
        </div>
        <div style={{ height: 4, background: 'var(--rule-hair)', position: 'relative' }}>
          <div
            style={{
              height: '100%',
              width: `${pct}%`,
              background: 'var(--ink)',
              transition: 'width 1s linear',
            }}
          ></div>
        </div>
        <div
          className="muted"
          style={{
            fontSize: 11,
            marginTop: 8,
            display: 'flex',
            justifyContent: 'space-between',
          }}
        >
          <span>countdown is local · live data lands in PR-C (GET /v1/anchor/status)</span>
          <span>tier-1 ↦ tier-2 commit</span>
        </div>
      </Panel>

      <Panel title="── recent anchors" flush>
        <div style={{ padding: 20 }} className="muted">
          recent anchors will populate once the daemon exposes <span className="mono">GET /v1/anchor/status</span>{' '}
          (tracked for PR-C).
        </div>
      </Panel>
    </>
  );
}
