'use client';

import { useEffect, useState, type ReactNode } from 'react';
import { NAMESPACES } from './data';
import { ActorTree, Chip, Dot, Panel, PageHead, TripleToggle } from './shared';
import type { Actor, AuditEvent, ChipKind, Namespace, ScopeBits } from './types';

// ─── Page: Actors list ───────────────────────────────────────────
export function ActorsPage({ actors, onPick }: { actors: Actor[]; onPick: (id: string) => void }) {
  const master = actors.find((a) => a.role === 'master')!;
  const agents = actors.filter((a) => a.role === 'agent');
  const active = agents.filter((a) => a.lastActive === 'now' || a.lastActive.endsWith('m ago')).length;

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

      <div className="stats">
        <div className="stat">
          <div className="v">{agents.length}</div>
          <div className="k">agents bound</div>
          <div className="delta">+1 this week (FoloToy bear)</div>
        </div>
        <div className="stat">
          <div className="v">{active}</div>
          <div className="k">active now</div>
          <div className="delta">SSE feed live · tier-1</div>
        </div>
        <div className="stat">
          <div className="v">128</div>
          <div className="k">events / 2-min batch</div>
          <div className="delta">last anchor 14:23:11</div>
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
}: {
  actor: Actor;
  onUpdate: (id: string, patch: Partial<Actor>) => void;
  onBack: () => void;
  onRevoke: (a: Actor) => void;
  onRevokeScope: (a: Actor, cap: string) => void;
  recentEvents: AuditEvent[];
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
            <TripleToggle value={actor.scope![ns]} onChange={(v) => setScope(ns, v)} />
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
              value={actor.paymentCap!.perTx}
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
            <span className="muted">{actor.paymentCap!.currency}</span>
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
              value={actor.paymentCap!.daily}
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
            <span className="muted">{actor.paymentCap!.currency}</span>
          </div>
        </div>
        <div className="toggle-row">
          <div>
            <div className="lbl">time window</div>
            <div className="desc">payments outside this window are rejected at broker</div>
          </div>
          <div className="mono">
            {actor.timeWindow!.start} <span className="muted">→</span> {actor.timeWindow!.end}
          </div>
        </div>
      </Panel>

      <Panel title="── cap-tokens · live · per-actor revoke" flush>
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
            <CapRow
              cap="memory:read"
              scope="family · personal"
              ttl="900s"
              minted="14:32"
              onRevoke={() => onRevokeScope(actor, 'memory:read')}
            />
            <CapRow
              cap="memory:write"
              scope="family"
              ttl="600s"
              minted="14:31"
              onRevoke={() => onRevokeScope(actor, 'memory:write')}
            />
            {actor.paymentCap!.perTx > 0 && (
              <CapRow
                cap="payment:execute"
                scope={`p-tx ≤ ${actor.paymentCap!.perTx} USDC`}
                ttl="60s"
                minted="14:31"
                onRevoke={() => onRevokeScope(actor, 'payment:execute')}
                danger
              />
            )}
            <CapRow
              cap="audit:append"
              scope="own log"
              ttl="3600s"
              minted="14:28"
              onRevoke={() => onRevokeScope(actor, 'audit:append')}
            />
          </tbody>
        </table>
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

function CapRow({
  cap,
  scope,
  ttl,
  minted,
  onRevoke,
  danger,
}: {
  cap: string;
  scope: string;
  ttl: string;
  minted: string;
  onRevoke: () => void;
  danger?: boolean;
}) {
  return (
    <tr>
      <td>
        <span className="mono">{cap}</span>
      </td>
      <td className="muted">{scope}</td>
      <td className="mono">{ttl}</td>
      <td className="muted">{minted}</td>
      <td className="right">
        <button className={`btn sm ${danger ? 'danger' : ''}`} onClick={onRevoke}>
          revoke
        </button>
      </td>
    </tr>
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
          <dt>current wallet</dt>
          <dd className="mono">
            0xf3a8…b1d2 <span className="muted">· K3 epoch v1</span>
          </dd>
          <dt>device pubkey</dt>
          <dd className="mono">
            {actor.devicePubkey} <span className="muted">· K10 secp256k1 · SE</span>
          </dd>
          <dt>K11 (WebAuthn)</dt>
          <dd>enrolled · platform authenticator · iOS Secure Enclave</dd>
          <dt>roles on chain</dt>
          <dd>CAP_MINT · RECOVERY · SCOPE_MGMT</dd>
          <dt>recovery threshold</dt>
          <dd>
            1-of-2 <span className="muted">· iPad (laptop offline)</span>
          </dd>
        </dl>
      </Panel>

      <Panel title="── master devices · multi-device quorum" flush>
        <table className="tab">
          <thead>
            <tr>
              <th></th>
              <th>device</th>
              <th>roles</th>
              <th>last K11 assertion</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <Dot status="ok" />
              </td>
              <td>iPhone 17 Pro · this device</td>
              <td className="mono">CAP_MINT | RECOVERY | SCOPE_MGMT</td>
              <td className="muted">14:32 just now</td>
            </tr>
            <tr>
              <td>
                <Dot status="muted" />
              </td>
              <td>iPad Pro · home</td>
              <td className="mono">CAP_MINT | RECOVERY</td>
              <td className="muted">yesterday 21:08</td>
            </tr>
          </tbody>
        </table>
      </Panel>

      <div className="banner">
        <span className="lbl">recovery</span>
        <span>If this device is lost, your iPad alone can revoke + rotate within ~60s. No anchor wallet, no seed phrase.</span>
      </div>
    </>
  );
}

// ─── Page: Audit feed ────────────────────────────────────────────
export function AuditPage({
  events,
  onPick,
  paused,
  onPause,
}: {
  events: AuditEvent[];
  onPick: (e: AuditEvent) => void;
  paused: boolean;
  onPause: () => void;
}) {
  const [filter, setFilter] = useState<ChipKind | 'all'>('all');
  const filtered = filter === 'all' ? events : events.filter((e) => e.chip === filter);
  const filters: (ChipKind | 'all')[] = ['all', 'memory', 'creds', 'payment', 'audit', 'chain'];

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
          <Dot status="ok" pulse={!paused} />
          {paused ? 'paused' : 'live'}
        </span>
        <span>
          {paused
            ? 'feed paused — incoming events queue at the broker SSE buffer.'
            : 'streaming from /v1/audit/stream · 1 connection · auto-reconnect on drop.'}{' '}
          <span className="muted">last 2-min batch: 128 events · root 0x7e3f…b8a1 anchored ✓</span>
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
    const lastAnchor = new Date(now);
    lastAnchor.setHours(14, 23, 11, 0);
    elapsed = Math.max(0, Math.floor((now - lastAnchor.getTime()) / 1000) % 120);
    next = 120 - elapsed;
    pct = (elapsed / 120) * 100;
  }

  const batches = [
    { ts: '14:23:11', root: '0x7e3f9c1a…b8a1', count: 128, txn: '0x4d2a…3f01', conf: 12 },
    { ts: '14:21:09', root: '0x3a1bc402…7d92', count: 142, txn: '0x9c8f…8a23', conf: 73 },
    { ts: '14:19:08', root: '0x91f2ec84…2055', count: 119, txn: '0x1b5e…ff10', conf: 134 },
    { ts: '14:17:07', root: '0xc4d870e1…013a', count: 156, txn: '0x77ae…5d8c', conf: 195 },
    { ts: '14:15:06', root: '0x0a92fb5d…e8c3', count: 134, txn: '0x2f01…b9d4', conf: 256 },
  ];

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
              {Math.round(34 + elapsed * 0.6)}
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
          <span>building Merkle tree …</span>
          <span>tier-1 ↦ tier-2 commit</span>
        </div>
      </Panel>

      <Panel title="── recent anchors" flush>
        <table className="tab">
          <thead>
            <tr>
              <th>time</th>
              <th>Merkle root</th>
              <th className="right">events</th>
              <th>extrinsic</th>
              <th className="right">confirmations</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {batches.map((b) => (
              <tr key={b.ts}>
                <td className="mono">{b.ts}</td>
                <td className="mono">{b.root}</td>
                <td className="right mono">{b.count}</td>
                <td className="mono">{b.txn}</td>
                <td className="right mono">{b.conf}</td>
                <td className="right">
                  <a href="#" onClick={(e) => e.preventDefault()} style={{ fontSize: 11 }}>
                    explorer ↗
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      <div className="banner">
        <span className="lbl">why</span>
        <span>
          Tier-1 SSE gives you sub-200ms reaction time. Tier-2 anchor on chain is the tamper-proof base of trust — any
          tier-1 event can be checked against its Merkle root on the public Litentry block explorer.
        </span>
      </div>
    </>
  );
}
