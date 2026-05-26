'use client';

import { useState } from 'react';
import { Chip, Panel, PageHead } from './shared';
import type { Actor, Worker } from './types';

const WORKERS: Worker[] = [
  {
    id: 'memory',
    title: 'memory-service',
    host: 'memory.litentry.org',
    desc: 'Read/write agent state in S3. High-frequency reads via STS. AAD bound to (actor_omni, namespace).',
    callsToday: 12483,
    callsHour: 612,
    p50: 38,
    p95: 142,
    cap: 'mem:r · mem:w',
    byActor: [
      { actor: 'FoloToy bear', count: 4831, share: 0.39 },
      { actor: 'Pluto', count: 3902, share: 0.31 },
      { actor: 'ChatGPT', count: 2110, share: 0.17 },
      { actor: 'Claude', count: 1640, share: 0.13 },
    ],
  },
  {
    id: 'credentials',
    title: 'credentials-service',
    host: 'creds.litentry.org',
    desc: 'Decrypt API credentials under per-user KEK (AES-256-GCM). Caller presents cap-token; worker re-verifies on chain.',
    callsToday: 312,
    callsHour: 18,
    p50: 71,
    p95: 220,
    cap: 'cred:r · cred:w',
    byActor: [
      { actor: 'ChatGPT', count: 142, share: 0.46 },
      { actor: 'Claude', count: 98, share: 0.31 },
      { actor: 'FoloToy bear', count: 42, share: 0.13 },
      { actor: 'Pluto', count: 30, share: 0.10 },
    ],
  },
  {
    id: 'audit',
    title: 'audit-service',
    host: 'audit.litentry.org',
    desc: 'Append-only per-actor audit log. Tier-1 SSE feed (this UI subscribes). Tier-2 anchors Merkle root every 2 min.',
    callsToday: 32104,
    callsHour: 1820,
    p50: 12,
    p95: 41,
    cap: 'audit:append',
    byActor: [
      { actor: 'Pluto', count: 12480, share: 0.39 },
      { actor: 'FoloToy bear', count: 9908, share: 0.31 },
      { actor: 'ChatGPT', count: 6011, share: 0.19 },
      { actor: 'Claude', count: 3705, share: 0.11 },
    ],
  },
  {
    id: 'email',
    title: 'email-service',
    host: 'mail.litentry.org',
    desc: 'Outbound via SES from operator domain (DKIM K9). Inbound to S3 inbox. Per-actor sub-addressing.',
    callsToday: 47,
    callsHour: 3,
    p50: 184,
    p95: 612,
    cap: 'mail:send · mail:inbox',
    byActor: [
      { actor: 'Pluto', count: 28, share: 0.60 },
      { actor: 'ChatGPT', count: 12, share: 0.25 },
      { actor: 'Claude', count: 7, share: 0.15 },
    ],
  },
  {
    id: 'payment',
    title: 'payment-service',
    host: 'pay.litentry.org',
    desc: 'Class-C one-shot CAS-burn caps. Modes P-1/P-2/P-3. Above per-tx threshold requires K11 assertion.',
    callsToday: 18,
    callsHour: 2,
    p50: 1820,
    p95: 4400,
    cap: 'pay:execute',
    byActor: [
      { actor: 'FoloToy bear', count: 14, share: 0.78 },
      { actor: 'Pluto', count: 4, share: 0.22 },
    ],
  },
];

const HUE_BY_WORKER: Record<Worker['id'], number> = {
  memory: 180,
  credentials: 295,
  audit: 145,
  email: 220,
  payment: 50,
};

export function WorkersPage({
  actors,
  onPickActor,
}: {
  actors: Actor[];
  onPickActor: (id: string) => void;
}) {
  const [selected, setSelected] = useState<Worker['id'] | null>(null);
  const worker = selected ? WORKERS.find((w) => w.id === selected)! : null;

  if (worker) {
    return (
      <WorkerDetail
        worker={worker}
        onBack={() => setSelected(null)}
        actors={actors}
        onPickActor={onPickActor}
      />
    );
  }

  return (
    <>
      <PageHead
        crumb="workers · five per-data-class executors"
        title={
          <>
            <span className="muted serif">/</span> workers
          </>
        }
        desc="Each worker holds no secrets at rest — per-invocation STS creds, mTLS to the signer enclave, independent chain re-verification on every cap. Tap any worker for per-actor usage."
      />

      <div className="workers-grid">
        {WORKERS.map((w) => (
          <div
            key={w.id}
            className="worker-card"
            data-worker={w.id}
            onClick={() => setSelected(w.id)}
            style={{ cursor: 'pointer' }}
          >
            <div className="w-head">
              <div>
                <div className="name">{w.title}</div>
                <div className="muted" style={{ fontSize: 11, marginTop: 2 }}>
                  {w.host}
                </div>
              </div>
              <span className="who">{w.cap}</span>
            </div>
            <div className="w-body">
              <div className="desc">{w.desc}</div>
              <div className="w-stats">
                <div className="w-stat">
                  <div className="v">{w.callsToday.toLocaleString()}</div>
                  <div className="k">calls · today</div>
                </div>
                <div className="w-stat">
                  <div className="v">{w.callsHour}</div>
                  <div className="k">last hour</div>
                </div>
                <div className="w-stat">
                  <div className="v">
                    {w.p50}
                    <span style={{ fontSize: 12 }}>ms</span>
                  </div>
                  <div className="k">p50 latency</div>
                </div>
                <div className="w-stat">
                  <div className="v">
                    {w.p95}
                    <span style={{ fontSize: 12 }}>ms</span>
                  </div>
                  <div className="k">p95 latency</div>
                </div>
              </div>
              <div
                style={{
                  fontSize: 10,
                  letterSpacing: '0.1em',
                  textTransform: 'uppercase',
                  color: 'var(--ink-faint)',
                  marginBottom: 6,
                }}
              >
                share by actor
              </div>
              {w.byActor.slice(0, 4).map((a) => (
                <div key={a.actor} className="actor-line">
                  <span>{a.actor}</span>
                  <span className="muted">{(a.share * 100).toFixed(0)}%</span>
                  <span className="cnt">{a.count.toLocaleString()}</span>
                </div>
              ))}
              <div style={{ marginTop: 12, fontSize: 11, color: 'var(--ink-faint)' }}>inspect →</div>
            </div>
          </div>
        ))}
      </div>

      <div className="banner" style={{ marginTop: 22 }}>
        <span className="lbl">why split</span>
        <span>
          Compromise of any one worker yields bounded damage — no shared IAM, no shared S3 prefix, no shared cap-token
          authority. See arch.md §3 (blast-radius table).
        </span>
      </div>
    </>
  );
}

function WorkerDetail({
  worker,
  onBack,
  actors,
  onPickActor,
}: {
  worker: Worker;
  onBack: () => void;
  actors: Actor[];
  onPickActor: (id: string) => void;
}) {
  const hue = HUE_BY_WORKER[worker.id];
  return (
    <>
      <PageHead
        crumb={
          <>
            <a onClick={onBack} style={{ cursor: 'pointer' }}>
              workers
            </a>{' '}
            <span className="muted">/</span> {worker.id}
          </>
        }
        title={
          <>
            <span className="muted serif">/</span> {worker.title}
          </>
        }
        desc={worker.desc}
        actions={
          <button className="btn" onClick={onBack}>
            ← back
          </button>
        }
      />

      <div className="worker-card" data-worker={worker.id} style={{ marginBottom: 22 }}>
        <div className="w-head">
          <div>
            <div className="name">{worker.title}</div>
            <div className="muted" style={{ fontSize: 11, marginTop: 2 }}>
              {worker.host} · mTLS to signer · STS minted per call
            </div>
          </div>
          <Chip kind="default">{worker.cap}</Chip>
        </div>
        <div className="w-body">
          <div className="w-stats" style={{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
            <div className="w-stat">
              <div className="v">{worker.callsToday.toLocaleString()}</div>
              <div className="k">calls today</div>
            </div>
            <div className="w-stat">
              <div className="v">{worker.callsHour}</div>
              <div className="k">last hour</div>
            </div>
            <div className="w-stat">
              <div className="v">
                {worker.p50}
                <span style={{ fontSize: 12 }}>ms</span>
              </div>
              <div className="k">p50</div>
            </div>
            <div className="w-stat">
              <div className="v">
                {worker.p95}
                <span style={{ fontSize: 12 }}>ms</span>
              </div>
              <div className="k">p95</div>
            </div>
          </div>
        </div>
      </div>

      <Panel title={`── usage by actor · ${worker.title}`} flush>
        <table className="tab">
          <thead>
            <tr>
              <th>actor</th>
              <th>derivation</th>
              <th>share</th>
              <th className="right">calls (24h)</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {worker.byActor.map((line) => {
              const actor =
                actors.find((a) => a.label.startsWith(line.actor.split(' ')[0])) ||
                actors.find((a) => line.actor.includes(a.label.split(' ')[0]));
              return (
                <tr
                  key={line.actor}
                  className={actor ? 'clickable' : ''}
                  onClick={() => actor && onPickActor(actor.id)}
                >
                  <td>{line.actor}</td>
                  <td className="mono muted">{actor ? actor.derivation : '—'}</td>
                  <td>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <div
                        style={{
                          width: 120,
                          height: 4,
                          background: 'var(--rule-hair)',
                          position: 'relative',
                        }}
                      >
                        <div
                          style={{
                            width: `${line.share * 100}%`,
                            height: '100%',
                            background: `oklch(0.5 0.12 ${hue})`,
                          }}
                        ></div>
                      </div>
                      <span className="muted mono" style={{ fontSize: 11 }}>
                        {(line.share * 100).toFixed(0)}%
                      </span>
                    </div>
                  </td>
                  <td className="right mono">{line.count.toLocaleString()}</td>
                  <td className="right">
                    {actor && (
                      <button
                        className="btn sm"
                        onClick={(e) => {
                          e.stopPropagation();
                          onPickActor(actor.id);
                        }}
                      >
                        actor →
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Panel>

      <Panel title="── trust profile">
        <dl className="kvs">
          <dt>secrets at rest</dt>
          <dd>none</dd>
          <dt>iam principal</dt>
          <dd className="mono">{`arn:aws:sts:::*:assumed-role/agentkeys-${worker.id}-v1`}</dd>
          <dt>session ttl</dt>
          <dd className="mono">3600s · refreshed per-call</dd>
          <dt>chain re-verify</dt>
          <dd>every cap-token · ScopeContract + SidecarRegistry + K3EpochCounter</dd>
          <dt>storage</dt>
          <dd className="mono">
            {`s3://${
              worker.id === 'payment' ? 'PAYMENT_AUDIT_BUCKET' : `${worker.id.toUpperCase()}_BUCKET`
            }/bots/<actor_omni_hex>/`}
          </dd>
          <dt>compromise blast</dt>
          <dd>
            {worker.id === 'memory' &&
              'this worker only · cannot decrypt creds, cannot pay, cannot mint caps'}
            {worker.id === 'credentials' &&
              'this worker only · decrypt for valid caps · cannot mint caps · cannot reach other classes'}
            {worker.id === 'audit' &&
              'append spam possible (rejected on chain mismatch) · cannot read other workers'}
            {worker.id === 'email' && 'mail send/receive within DKIM domain only · K9 isolated'}
            {worker.id === 'payment' &&
              'cannot exceed per-tx cap · K11 gate above threshold · CAS-burn prevents replay'}
          </dd>
        </dl>
      </Panel>
    </>
  );
}
