'use client';

import { useEffect, useState } from 'react';
import { useClient } from '@/lib/ClientProvider';
import type { ConnectionStatus } from '@/lib/client/types';
import { Chip, EmptyState, Panel, PageHead } from './shared';
import type { Worker } from './types';

const HUE_BY_WORKER: Record<Worker['id'], number> = {
  memory: 180,
  credentials: 295,
  audit: 145,
  email: 220,
  payment: 50,
};

export function WorkersPage({
  status,
  onPickActor,
}: {
  status: ConnectionStatus;
  onPickActor: (id: string) => void;
}) {
  const client = useClient();
  const [workers, setWorkers] = useState<Worker[]>([]);
  const [selected, setSelected] = useState<Worker['id'] | null>(null);
  const worker = selected ? workers.find((w) => w.id === selected) ?? null : null;

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await client.listWorkers();
      if (!cancelled && r.ok) setWorkers(r.data);
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  if (worker) {
    return (
      <WorkerDetail
        worker={worker}
        onBack={() => setSelected(null)}
        onPickActor={onPickActor}
      />
    );
  }

  const isEmpty = workers.length === 0;

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

      {isEmpty ? (
        <EmptyState
          status={status}
          title="no workers reachable"
          hint={
            <>
              Workers report in via daemon endpoint <span className="mono">GET /v1/workers</span> (lands in PR-C). The
              five canonical workers per arch.md §15 are <span className="mono">memory</span>,{' '}
              <span className="mono">credentials</span>, <span className="mono">audit</span>,{' '}
              <span className="mono">email</span>, <span className="mono">payment</span>.
            </>
          }
        />
      ) : (
        <>
          <div className="workers-grid">
            {workers.map((w) => (
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
      )}
    </>
  );
}

function WorkerDetail({
  worker,
  onBack,
  onPickActor,
}: {
  worker: Worker;
  onBack: () => void;
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
              <th>share</th>
              <th className="right">calls (24h)</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {worker.byActor.map((line) => (
              <tr key={line.actor}>
                <td>{line.actor}</td>
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
                  <button
                    className="btn sm"
                    onClick={() => onPickActor(line.actor)}
                  >
                    actor →
                  </button>
                </td>
              </tr>
            ))}
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
