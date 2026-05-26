'use client';

import { PageHead, Panel } from './shared';

interface HarnessStep {
  num: number;
  title: string;
  source: string; // file:line reference in the harness script
  desc: string;
  invariant?: string;
}

const STAGE2_STEPS: HarnessStep[] = [
  {
    num: 1,
    title: 'build agentkeys CLI + agentkeys-daemon (release)',
    source: 'harness/v2-stage2-demo.sh:121',
    desc: 'cargo build --release -p agentkeys-cli agentkeys-daemon — stage-2 binaries.',
  },
  {
    num: 2,
    title: 'forge test suite (P256 + K11 + AgentKeysV1)',
    source: 'harness/v2-stage2-demo.sh:153',
    desc: '28 forge tests gate the stage-2 deploy. Run before any chain mutation.',
    invariant: 'P256Verifier.verify(r,s,e,Qx,Qy) === reference vector',
  },
  {
    num: 3,
    title: 'deploy stage-2 contracts',
    source: 'harness/v2-stage2-demo.sh:201',
    desc: 'P256Verifier, K11Verifier, fresh SidecarRegistry + AgentKeysScope ABI for on-chain K11 verify.',
  },
  {
    num: 4,
    title: 'bootstrap primary master',
    source: 'harness/v2-stage2-demo.sh:267',
    desc: 'register_master_device(D_pub, K11_credId) on the new SidecarRegistry. Reuses stage-1 D_pub.',
  },
  {
    num: 5,
    title: 'spin up companion daemon',
    source: 'harness/v2-stage2-demo.sh:319',
    desc: 'Second daemon instance on 127.0.0.1:9091. Holds a distinct K10 + K11 on rp_id "companion.localhost".',
  },
  {
    num: 6,
    title: 'register companion as 2nd master',
    source: 'harness/v2-stage2-demo.sh:402',
    desc: 'agentkeys device add — primary signs the registration; companion now appears in SidecarRegistry with CAP_MINT | RECOVERY.',
  },
  {
    num: 7,
    title: 'set recoveryThreshold = 2',
    source: 'harness/v2-stage2-demo.sh:471',
    desc: 'M-of-N quorum bumps to 2. Any single master can still mint caps, but recovery + device-revoke now requires both.',
    invariant: 'recoveryThreshold == 2 && registered_masters.length == 2',
  },
  {
    num: 8,
    title: 'recovery sanity-check ceremony',
    source: 'harness/v2-stage2-demo.sh:524',
    desc: 'Revoke-device-via-both-masters exercise. Both K11 assertions must land in the same extrinsic.',
  },
];

const STAGE3_STEPS: HarnessStep[] = [
  {
    num: 1,
    title: 'build CLI (if --skip-build absent)',
    source: 'harness/v2-stage3-demo.sh:80',
    desc: 'cargo build -p agentkeys-cli.',
  },
  {
    num: 2,
    title: 'STS assume-role-with-web-identity',
    source: 'harness/v2-stage3-demo.sh:215',
    desc: 'Exchange session JWT for AWS temp creds for vault + memory roles.',
    invariant: 'PrincipalTag/agentkeys_actor_omni == request actor_omni',
  },
  {
    num: 3,
    title: 'positive write — vault bucket',
    source: 'harness/v2-stage3-demo.sh:286',
    desc: 'write own credentials envelope to s3://vault/bots/<own>/credentials/test.json. Must 200.',
  },
  {
    num: 4,
    title: 'NEGATIVE write — cross-actor vault prefix',
    source: 'harness/v2-stage3-demo.sh:354',
    desc: 'Try to write under bots/<other_actor>/credentials/. Must 403 (PrincipalTag interp).',
    invariant: 'AccessDenied required — leakage = stage-3 fail',
  },
  {
    num: 5,
    title: 'NEGATIVE list — cross-actor vault prefix',
    source: 'harness/v2-stage3-demo.sh:412',
    desc: 's3:ListBucket with prefix=bots/<other>/credentials/. Must 403 (bucket policy condition).',
    invariant: 'AccessDenied required — directory enumeration impossible',
  },
  {
    num: 6,
    title: 'positive write — memory bucket',
    source: 'harness/v2-stage3-demo.sh:470',
    desc: 'write own memory envelope to s3://memory/bots/<own>/memory/.',
  },
  {
    num: 7,
    title: 'NEGATIVE write — cross-actor memory',
    source: 'harness/v2-stage3-demo.sh:538',
    desc: 'mirror of step 4 but on memory bucket. Must 403.',
  },
  {
    num: 8,
    title: 'NEGATIVE list — cross-actor memory',
    source: 'harness/v2-stage3-demo.sh:596',
    desc: 'mirror of step 5 but on memory bucket. Must 403.',
  },
  {
    num: 9,
    title: 'cross-bucket isolation',
    source: 'harness/v2-stage3-demo.sh:649',
    desc: 'Vault creds tried on memory bucket (and reverse). Both must 403.',
    invariant: 'IAM role scoped per data class (arch.md §17.2)',
  },
  {
    num: 10,
    title: 'credential worker roundtrip',
    source: 'harness/v2-stage3-demo.sh:718',
    desc: 'cap-mint /v1/cap/cred-store → worker /v1/cred/store → cap-mint /v1/cap/cred-fetch → worker /v1/cred/fetch.',
    invariant: 'plaintext_fetched === plaintext_stored',
  },
  {
    num: 11,
    title: 'memory worker roundtrip',
    source: 'harness/v2-stage3-demo.sh:823',
    desc: 'mirror of step 10 for /v1/memory/put + /v1/memory/get.',
  },
  {
    num: 12,
    title: 'cleanup test data',
    source: 'harness/v2-stage3-demo.sh:932',
    desc: 'admin-creds delete under bots/<test_actor>/* on both buckets.',
  },
  {
    num: 13,
    title: 'NEGATIVE cap-mint with cross-actor operator_omni',
    source: 'harness/v2-stage3-demo.sh:1003',
    desc: 'broker cap-mint must reject when JWT operator_omni ≠ requested operator_omni. Defense-in-depth layer 1.',
    invariant: 'HTTP 4xx; broker rejects before any worker is contacted',
  },
  {
    num: 14,
    title: 'NEGATIVE cred-class cap → memory worker',
    source: 'harness/v2-stage3-demo.sh:1027',
    desc: 'Submit a Credentials-class cap to the memory worker. Worker must reject with cap_data_class_mismatch.',
    invariant: 'Cap-layer isolation between data classes (arch.md cap-tokens-data-class-explicit)',
  },
  {
    num: 15,
    title: 'NEGATIVE memory-class cap → cred worker',
    source: 'harness/v2-stage3-demo.sh:1051',
    desc: 'Symmetric to step 14.',
  },
];

export function HarnessPage({ onClose }: { onClose: () => void }) {
  return (
    <>
      <PageHead
        crumb="harness · stage 2 + 3"
        title={
          <>
            <span className="muted serif">/</span> harness flows
          </>
        }
        desc="Mirrors harness/v2-stage2-demo.sh and harness/v2-stage3-demo.sh as readable step lists. These are the real CI gates — every step here either appears on the parent-control dashboard once the daemon's audit feed catches it (live SSE) or runs as a shell script the operator launches outside the browser. PR-D will add 'live status' badges per step."
        actions={
          <button className="btn" onClick={onClose}>
            ← back
          </button>
        }
      />

      <div className="banner">
        <span className="lbl">why these matter</span>
        <span>
          The 4-layer isolation invariants table from arch.md (broker cap-mint, worker chain-verify, AWS IAM PrincipalTag, per-data-class bucket separation) is whatever survives these scripts running green. A new PR that adds a worker, a data class, or a broker auth method MUST extend these flows with new negative tests.
        </span>
      </div>

      <Panel title={`── stage 2 · multi-master quorum · ${STAGE2_STEPS.length} steps`} flush>
        <table className="tab">
          <thead>
            <tr>
              <th style={{ width: 40 }}>#</th>
              <th>step</th>
              <th>source</th>
              <th>invariant</th>
            </tr>
          </thead>
          <tbody>
            {STAGE2_STEPS.map((s) => (
              <tr key={`s2-${s.num}`}>
                <td className="mono">{s.num}</td>
                <td>
                  <div style={{ fontWeight: 500 }}>{s.title}</div>
                  <div className="secondary" style={{ marginTop: 2 }}>
                    {s.desc}
                  </div>
                </td>
                <td className="mono muted" style={{ fontSize: 11 }}>
                  {s.source}
                </td>
                <td className="muted" style={{ fontSize: 11 }}>
                  {s.invariant ?? '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      <Panel title={`── stage 3 · per-actor + per-data-class isolation · ${STAGE3_STEPS.length} steps`} flush>
        <table className="tab">
          <thead>
            <tr>
              <th style={{ width: 40 }}>#</th>
              <th>step</th>
              <th>source</th>
              <th>invariant</th>
            </tr>
          </thead>
          <tbody>
            {STAGE3_STEPS.map((s) => (
              <tr key={`s3-${s.num}`}>
                <td className="mono">{s.num}</td>
                <td>
                  <div style={{ fontWeight: 500 }}>{s.title}</div>
                  <div className="secondary" style={{ marginTop: 2 }}>
                    {s.desc}
                  </div>
                </td>
                <td className="mono muted" style={{ fontSize: 11 }}>
                  {s.source}
                </td>
                <td className="muted" style={{ fontSize: 11 }}>
                  {s.invariant ?? '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      <Panel title="── operator runbook">
        <div style={{ fontSize: 12.5, lineHeight: 1.7 }}>
          <p style={{ marginTop: 0 }}>
            Run the full chain against a real broker:
          </p>
          <pre
            style={{
              background: 'var(--bg-elev)',
              padding: '10px 12px',
              border: '1px solid var(--rule-soft)',
              fontSize: 11.5,
              overflowX: 'auto',
              margin: 0,
            }}
          >
{`# stage 1 — identity + K10 + K11 + chain bring-up + first device register
AGENTKEYS_CHAIN=heima bash harness/v2-stage1-demo.sh

# stage 2 — companion daemon + recovery threshold 2
AGENTKEYS_CHAIN=heima bash harness/v2-stage2-demo.sh

# stage 3 — 4-layer isolation (cap-mint, worker chain-verify, IAM, bucket)
AGENTKEYS_CHAIN=heima bash harness/v2-stage3-demo.sh`}
          </pre>
          <p style={{ marginBottom: 0 }}>
            Each script is idempotent (see CLAUDE.md idempotent-remote-setup-rule). Re-running picks up
            where it left off; partial state on chain or in AWS is detected and skipped.
          </p>
        </div>
      </Panel>
    </>
  );
}
