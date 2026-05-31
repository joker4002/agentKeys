'use client';

import { useEffect, useState } from 'react';
import { txHash } from '@/lib/demoData';
import { ONBOARDING_STEPS } from '@/lib/demoData';
import type { CeremonyStep } from './types';

// Shared progress-bar ceremony with a live step log + per-step tx hashes.
export function CeremonyRunner({
  steps,
  onDone,
  accent = '#1a1815',
  stepMs = 750,
}: {
  steps: CeremonyStep[];
  onDone: () => void;
  accent?: string;
  stepMs?: number;
}) {
  const [done, setDone] = useState(0);
  const [txs, setTxs] = useState<Record<number, string>>({});

  useEffect(() => {
    if (done >= steps.length) {
      const t = setTimeout(onDone, 700);
      return () => clearTimeout(t);
    }
    const t = setTimeout(() => {
      const step = steps[done];
      if (step.onchain) {
        setTxs((prev) => ({ ...prev, [done]: txHash(step.label + done) }));
      }
      setDone((d) => d + 1);
    }, stepMs);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [done]);

  const pct = Math.round((done / steps.length) * 100);

  return (
    <div className="ceremony">
      <div className="ceremony-bar-wrap">
        <div className="ceremony-bar-track">
          <div className="ceremony-bar-fill" style={{ width: `${pct}%`, background: accent }} />
        </div>
        <div className="ceremony-bar-meta">
          <span>{done >= steps.length ? 'complete' : 'working…'}</span>
          <span className="mono">
            {Math.min(done, steps.length)}/{steps.length} · {pct}%
          </span>
        </div>
      </div>

      <div className="ceremony-log">
        {steps.map((s, i) => {
          const status = i < done ? 'done' : i === done ? 'running' : 'pending';
          return (
            <div key={i} className={`clog-row ${status}`}>
              <span className="clog-mark">{status === 'done' ? '✓' : status === 'running' ? '▸' : '·'}</span>
              <div className="clog-body">
                <div className="clog-label">
                  {s.label}
                  {s.onchain && <span className="clog-chain">on-chain</span>}
                </div>
                <div className="clog-sub">{s.sub}</div>
                {txs[i] && <div className="clog-tx mono">tx {txs[i].slice(0, 22)}… · heima · confirmed</div>}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// Full-screen WebAuthn login → onboarding ceremony (workflow 1).
export function OnboardingScreen({ onComplete }: { onComplete: () => void }) {
  const [phase, setPhase] = useState<'login' | 'scanning' | 'ceremony'>('login');

  const startLogin = () => {
    setPhase('scanning');
    setTimeout(() => setPhase('ceremony'), 1300);
  };

  return (
    <div className="onboard">
      <div className="onboard-card">
        <div className="onboard-brand">
          <div
            style={{
              width: 56, height: 56, border: '1px solid var(--rule)', display: 'grid',
              placeItems: 'center', fontSize: 28, color: 'var(--ink)',
            }}
            aria-hidden
          >
            ◐
          </div>
          <div>
            <div className="serif" style={{ fontSize: 30, fontStyle: 'italic', letterSpacing: '-0.02em', lineHeight: 1 }}>
              agentKeys
            </div>
            <div style={{ fontSize: 11, color: 'var(--ink-dim)', letterSpacing: '0.1em', textTransform: 'uppercase', marginTop: 6 }}>
              sovereign keys · for agents
            </div>
          </div>
        </div>

        <div className="hr-ascii" style={{ margin: '20px 0' }}>{'─'.repeat(220)}</div>

        {phase === 'login' && (
          <div className="onboard-login">
            <h1 className="serif" style={{ fontSize: 22, fontStyle: 'italic', margin: '0 0 6px' }}>Welcome back, Sara.</h1>
            <p style={{ fontSize: 12.5, color: 'var(--ink-dim)', marginBottom: 22, maxWidth: 380 }}>
              Your master identity is anchored to this device&apos;s Secure Enclave. No password, no seed phrase — just the
              passkey you enrolled. Sign in to bring up your dashboard.
            </p>
            <button
              className="btn primary"
              style={{ width: '100%', justifyContent: 'center', padding: '12px' }}
              onClick={startLogin}
            >
              ◐ Sign in with passkey · Touch ID
            </button>
            <div style={{ fontSize: 10.5, color: 'var(--ink-faint)', marginTop: 14, textAlign: 'center' }}>
              rp_id = localhost · O_master · 0xa3f1…c92e
            </div>
          </div>
        )}

        {phase === 'scanning' && (
          <div className="wa-fingerprint" style={{ padding: '30px 0' }}>
            <div className="fp-ring scanning"><span className="glyph">fp</span></div>
            <div className="fp-msg">Verifying passkey assertion…</div>
          </div>
        )}

        {phase === 'ceremony' && (
          <div>
            <div style={{ fontSize: 11, letterSpacing: '0.1em', textTransform: 'uppercase', color: 'var(--ink-dim)', marginBottom: 14 }}>
              Bringing up your trust core
            </div>
            <CeremonyRunner steps={ONBOARDING_STEPS} onDone={onComplete} stepMs={620} />
          </div>
        )}
      </div>
    </div>
  );
}
