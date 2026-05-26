'use client';

import { useEffect, useState } from 'react';
import { useClient } from '@/lib/ClientProvider';
import {
  credentialToFinishPayload,
  jsonToCreationOptions,
  platformAuthenticatorAvailable,
  webauthnAvailable,
} from '@/lib/webauthn';
import { Panel, PageHead } from './shared';

type StepStatus = 'pending' | 'running' | 'done' | 'failed' | 'skipped';

interface Step {
  id: string;
  num: number;
  title: string;
  desc: string;
  detail?: string;
  status: StepStatus;
  error?: string;
}

const INITIAL_STEPS: Step[] = [
  {
    id: 'identity',
    num: 1,
    title: 'identity ceremony',
    desc: 'email-link / OAuth — broker returns binding_nonce',
    detail: 'Stubbed in PR-B. The CLI command agentkeys init runs this today.',
    status: 'pending',
  },
  {
    id: 'k10',
    num: 2,
    title: 'K10 device key',
    desc: 'generate secp256k1 keypair in Secure Enclave',
    detail: 'Stubbed in PR-B. The CLI command agentkeys signer derive runs this today.',
    status: 'pending',
  },
  {
    id: 'k11',
    num: 3,
    title: 'K11 WebAuthn enrollment',
    desc: 'navigator.credentials.create() → platform authenticator → daemon → SidecarRegistry',
    detail: 'Live. Browser drives the real WebAuthn ceremony. Daemon /v1/k11/enroll/{begin,finish}.',
    status: 'pending',
  },
  {
    id: 'siwe',
    num: 4,
    title: 'SIWE → session JWT',
    desc: 'sign Sign-In-With-Ethereum message, exchange for broker K6 token',
    detail: 'Stubbed in PR-B.',
    status: 'pending',
  },
  {
    id: 'sts',
    num: 5,
    title: 'STS assume-role-with-web-identity',
    desc: 'exchange session JWT for AWS temp creds (vault + memory)',
    detail: 'Stubbed in PR-B. The harness step 7 in v2-stage1-demo.sh runs this against the real broker.',
    status: 'pending',
  },
  {
    id: 'provision',
    num: 6,
    title: 'provision vault + memory buckets',
    desc: 'one-shot idempotent S3 bucket + IAM role bring-up',
    detail: 'Stubbed in PR-B. The harness step 7 in v2-stage1-demo.sh runs this.',
    status: 'pending',
  },
  {
    id: 'chain',
    num: 7,
    title: 'chain bring-up',
    desc: 'deploy SidecarRegistry + AgentKeysScope + K3EpochCounter + CredentialAudit',
    detail: 'Stubbed in PR-B. Real chain deploy lives in scripts/heima-bring-up.sh.',
    status: 'pending',
  },
  {
    id: 'register',
    num: 8,
    title: 'register master device on chain',
    desc: 'SidecarRegistry.register_master_device(D_pub, K11_credId)',
    detail: 'Stubbed in PR-B. Real chain submission lands in PR-C alongside the audit-service feed.',
    status: 'pending',
  },
];

export function OnboardingPage({ onClose }: { onClose: () => void }) {
  const client = useClient();
  const [steps, setSteps] = useState<Step[]>(INITIAL_STEPS);
  const [platformOk, setPlatformOk] = useState<boolean | null>(null);
  const [username, setUsername] = useState('sara@example.com');
  const [displayName, setDisplayName] = useState('Sara (master)');

  useEffect(() => {
    if (!webauthnAvailable()) {
      setPlatformOk(false);
      return;
    }
    platformAuthenticatorAvailable().then(setPlatformOk);
  }, []);

  const setStatus = (id: string, status: StepStatus, error?: string) => {
    setSteps((prev) => prev.map((s) => (s.id === id ? { ...s, status, error } : s)));
  };

  const runStubStep = async (id: string) => {
    setStatus(id, 'running');
    await new Promise((r) => setTimeout(r, 400));
    setStatus(id, 'skipped', 'Stubbed in PR-B; real flow lands in PR-C / v2-stage1 harness.');
  };

  const runK11Enroll = async () => {
    if (!webauthnAvailable()) {
      setStatus('k11', 'failed', 'WebAuthn not available in this browser.');
      return;
    }
    setStatus('k11', 'running');
    try {
      const beginResult = await client.enrollK11Begin({
        userName: username,
        userDisplayName: displayName,
      });
      if (!beginResult.ok) {
        setStatus('k11', 'failed', `begin failed: ${beginResult.status.detail ?? beginResult.status.reason}`);
        return;
      }
      const begin = beginResult.data;

      const creationOptions = jsonToCreationOptions({
        rp: { id: begin.rpId, name: begin.rpName },
        user: { id: begin.userId, name: begin.userName, displayName: begin.userDisplayName },
        challenge: begin.challenge,
        pubKeyCredParams: begin.pubKeyCredParams,
        timeout: begin.timeout,
        attestation: 'none',
        authenticatorSelection: {
          authenticatorAttachment: 'platform',
          userVerification: 'required',
          residentKey: 'preferred',
        },
      });

      const cred = (await navigator.credentials.create({ publicKey: creationOptions })) as PublicKeyCredential | null;
      if (!cred) {
        setStatus('k11', 'failed', 'navigator.credentials.create() returned null');
        return;
      }
      const payload = credentialToFinishPayload(cred);

      const finishResult = await client.enrollK11Finish({
        credentialId: payload.credentialId,
        attestationObject: payload.attestationObject,
        clientDataJSON: payload.clientDataJSON,
        bindingNonce: begin.userId,
      });

      if (!finishResult.ok) {
        setStatus('k11', 'failed', `finish failed: ${finishResult.status.detail ?? finishResult.status.reason}`);
        return;
      }
      setStatus('k11', 'done');
    } catch (err) {
      const msg = (err as Error).message ?? String(err);
      setStatus('k11', 'failed', `ceremony aborted: ${msg}`);
    }
  };

  const runStep = (s: Step) => {
    if (s.id === 'k11') return runK11Enroll();
    return runStubStep(s.id);
  };

  return (
    <>
      <PageHead
        crumb="onboarding · v2-stage1 mirror"
        title={
          <>
            <span className="muted serif">/</span> first-run onboarding
          </>
        }
        desc="Mirrors harness/v2-stage1-demo.sh as an interactive wizard. Step 3 (K11 WebAuthn) is live and runs a real browser ceremony against the daemon's /v1/k11/enroll endpoints. The other steps are stubbed in PR-B; real implementations land in PR-C."
        actions={
          <button className="btn" onClick={onClose}>
            ← back
          </button>
        }
      />

      <Panel title="── prereqs">
        <div className="kvs" style={{ display: 'grid', gridTemplateColumns: '180px 1fr', gap: '6px 16px' }}>
          <div className="muted" style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
            WebAuthn supported
          </div>
          <div>{platformOk === null ? '…' : platformOk ? 'yes · platform authenticator' : 'no'}</div>
          <div className="muted" style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
            daemon backend
          </div>
          <div className="mono">{process.env.NEXT_PUBLIC_AGENTKEYS_BACKEND ?? 'empty'} · expected `daemon`</div>
          <div className="muted" style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
            ui-bridge URL
          </div>
          <div className="mono">{process.env.NEXT_PUBLIC_AGENTKEYS_DAEMON_URL ?? 'http://localhost:3114'}</div>
        </div>
      </Panel>

      <Panel title="── master identity (used for K11 enrollment)">
        <div className="toggle-row">
          <div>
            <div className="lbl">username</div>
            <div className="desc">passed to navigator.credentials.create as user.name</div>
          </div>
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            style={{
              width: 240,
              padding: '4px 8px',
              fontFamily: 'inherit',
              fontSize: 13,
              border: '1px solid var(--rule)',
              background: 'var(--bg)',
              color: 'var(--ink)',
            }}
          />
        </div>
        <div className="toggle-row">
          <div>
            <div className="lbl">display name</div>
            <div className="desc">shown by the platform authenticator UI</div>
          </div>
          <input
            type="text"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            style={{
              width: 240,
              padding: '4px 8px',
              fontFamily: 'inherit',
              fontSize: 13,
              border: '1px solid var(--rule)',
              background: 'var(--bg)',
              color: 'var(--ink)',
            }}
          />
        </div>
      </Panel>

      <Panel title="── v2-stage1 steps" flush>
        <table className="tab">
          <thead>
            <tr>
              <th style={{ width: 40 }}>#</th>
              <th>step</th>
              <th>desc</th>
              <th>status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {steps.map((s) => (
              <tr key={s.id}>
                <td className="mono">{s.num}</td>
                <td>
                  <span style={{ fontWeight: s.id === 'k11' ? 600 : 400 }}>{s.title}</span>
                  {s.detail && (
                    <div className="secondary" style={{ marginTop: 2 }}>
                      {s.detail}
                    </div>
                  )}
                  {s.error && (
                    <div
                      className="secondary"
                      style={{ marginTop: 4, color: 'var(--danger)' }}
                    >
                      {s.error}
                    </div>
                  )}
                </td>
                <td className="muted">{s.desc}</td>
                <td>
                  <StatusChip status={s.status} />
                </td>
                <td className="right">
                  <button
                    className={`btn sm ${s.id === 'k11' ? 'primary' : ''}`}
                    onClick={() => runStep(s)}
                    disabled={s.status === 'running' || s.status === 'done'}
                  >
                    {s.status === 'done' ? '✓ done' : s.status === 'running' ? '…' : 'run'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      <div className="banner">
        <span className="lbl">scope</span>
        <span>
          Step 3 is the only step with a real implementation in PR-B — a genuine browser WebAuthn ceremony backed by the
          daemon&apos;s ui-bridge mode. PR-C wires steps 1, 2, 4–8 to the broker + chain. To run step 3, start the daemon
          with <span className="mono">agentkeys-daemon --ui-bridge</span> and set <span className="mono">NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon</span>{' '}
          in <span className="mono">.env.local</span>.
        </span>
      </div>
    </>
  );
}

function StatusChip({ status }: { status: StepStatus }) {
  if (status === 'pending') return <span className="chip">pending</span>;
  if (status === 'running') return <span className="chip warn">running…</span>;
  if (status === 'done') return <span className="chip ok">done</span>;
  if (status === 'skipped') return <span className="chip">stubbed</span>;
  return <span className="chip bad">failed</span>;
}
