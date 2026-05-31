'use client';

import { NAMESPACES } from '@/lib/constants';
import { PRESERVED_MEMORY } from '@/lib/demoData';
import { CeremonyRunner } from './ceremony';
import { PageHead, Panel } from './shared';
import type { CeremonyStep, PreservedMemory } from './types';

const PLANT_STEPS: CeremonyStep[] = [
  { label: 'Read preserved archive', sub: 'agentmemory://kevin.zhao · 5 entries · 1.2 KB', onchain: false },
  { label: 'Dedupe against existing', sub: 'content-hash compare · 0 collisions · safe to write', onchain: false },
  { label: 'Encrypt envelopes', sub: 'AES-256-GCM under K3 epoch v1 KEK · per (actor, key)', onchain: false },
  { label: 'Write to memory bucket', sub: 's3://agentkeys-memory-prod/bots/<omni>/<ns>/<key>.enc', onchain: false },
  { label: 'Index + audit', sub: 'CredentialAudit.append(op=memory.plant) · tier-1 + anchor', onchain: true, fn: 'append(bytes32,bytes32,bytes32)' },
];

// Workflow 2: see memories; plant preserved memory if none (auto-detect, dedup).
export function MemoryPage({
  memories,
  onPlant,
  planting,
  onPlantDone,
  onView,
}: {
  memories: PreservedMemory[];
  onPlant: () => void;
  planting: boolean;
  onPlantDone: () => void;
  onView: (m: PreservedMemory) => void;
}) {
  const hasMemory = memories.length > 0;
  const byNs = NAMESPACES.map((ns) => ({ ns, items: memories.filter((m) => m.ns === ns) })).filter((g) => g.items.length > 0);
  const totalBytes = memories.reduce((a, m) => a + m.bytes, 0);

  return (
    <>
      <PageHead
        crumb="memory · per-namespace · agentmemory-compatible"
        title={<><span className="muted serif">/</span> memory</>}
        desc="Your portable memory namespace — the spine agents read from and write to. It follows you across every vendor device. Stored encrypted; agents see only what their scope grants."
      />

      {!hasMemory && !planting && (
        <div className="empty-memory">
          <div className="serif" style={{ fontSize: 40, fontStyle: 'italic', color: 'var(--ink-faint)', marginBottom: 4 }}>∅</div>
          <h2 className="serif" style={{ fontSize: 22, fontStyle: 'italic', margin: '0 0 8px' }}>No memory planted yet.</h2>
          <p style={{ fontSize: 12.5, color: 'var(--ink-dim)', maxWidth: 440, margin: '0 auto 22px' }}>
            You have a preserved memory archive from agentmemory. Plant it here to give every paired agent the same
            context — who you are, your routines, your current trip. This is a one-time import; duplicates are detected
            and skipped automatically.
          </p>
          <button className="btn primary" style={{ padding: '12px 22px' }} onClick={onPlant}>
            ⊕ plant preserved memory
          </button>
          <div style={{ fontSize: 10.5, color: 'var(--ink-faint)', marginTop: 14 }}>
            source · agentmemory://kevin.zhao · {PRESERVED_MEMORY.length} entries · idempotent
          </div>
        </div>
      )}

      {planting && (
        <Panel title="── planting preserved memory">
          <CeremonyRunner steps={PLANT_STEPS} onDone={onPlantDone} stepMs={620} />
        </Panel>
      )}

      {hasMemory && (
        <>
          <div className="stats">
            <div className="stat"><div className="v">{memories.length}</div><div className="k">memory entries</div></div>
            <div className="stat"><div className="v">{byNs.length}</div><div className="k">namespaces</div></div>
            <div className="stat"><div className="v">{(totalBytes / 1024).toFixed(1)}<span style={{ fontSize: 13 }}>KB</span></div><div className="k">total size</div></div>
            <div className="stat"><div className="v">k3 v1</div><div className="k">epoch (kek)</div></div>
          </div>

          <div className="banner">
            <span className="lbl">✓ planted</span>
            <span>
              Preserved memory is live. The <strong>plant</strong> action is now hidden — re-planting is blocked because all
              {' '}{PRESERVED_MEMORY.length} entries already exist (content-hash match). Agents read this per their granted scope.
            </span>
          </div>

          {byNs.map((g) => (
            <Panel key={g.ns} title={`── ${g.ns} · ${g.items.length}`} flush>
              <table className="tab">
                <thead>
                  <tr>
                    <th>entry</th>
                    <th>preview</th>
                    <th className="right">bytes</th>
                    <th>updated</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {g.items.map((m) => (
                    <tr key={m.ns + m.key} className="clickable" onClick={() => onView(m)}>
                      <td>
                        <span className="mono" style={{ fontWeight: 500 }}>{m.title}</span>
                        <div className="secondary">{m.ns}/{m.key}</div>
                      </td>
                      <td className="muted" style={{ maxWidth: 360 }}>{m.preview}</td>
                      <td className="right mono">{m.bytes}</td>
                      <td className="muted">{m.updated}</td>
                      <td className="right"><button className="btn sm" onClick={(e) => { e.stopPropagation(); onView(m); }}>open</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Panel>
          ))}
        </>
      )}
    </>
  );
}
