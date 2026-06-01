'use client';

import { NAMESPACES } from '@/lib/constants';
import type { ConnectionStatus } from '@/lib/client/types';
import { EmptyState, PageHead, Panel } from './shared';
import type { PreservedMemory } from './types';

// Workflow 2: see the master's real memory (read-only). Entries come from the
// client seam (`listMasterMemory` → daemon → S3); there is no seed fixture and
// no fixture-plant button. Disconnected → empty state; connected + empty →
// neutral "no memory yet" copy.
export function MemoryPage({
  memories,
  status,
  onView,
}: {
  memories: PreservedMemory[];
  status: ConnectionStatus;
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

      {!hasMemory && (
        status.kind === 'connected' ? (
          <div className="empty-memory">
            <div className="serif" style={{ fontSize: 40, fontStyle: 'italic', color: 'var(--ink-faint)', marginBottom: 4 }}>∅</div>
            <h2 className="serif" style={{ fontSize: 22, fontStyle: 'italic', margin: '0 0 8px' }}>No memory yet.</h2>
            <p style={{ fontSize: 12.5, color: 'var(--ink-dim)', maxWidth: 440, margin: '0 auto' }}>
              Your memory namespace is empty. Paired agents write here as they work, and the entries you grant
              scope to appear in this view — encrypted at rest, decrypted on read.
            </p>
          </div>
        ) : (
          <EmptyState
            status={status}
            title="memory unavailable"
            hint="Master memory is read from the daemon (GET /v1/master/memory → S3). Connect a daemon to populate this view."
          />
        )
      )}

      {hasMemory && (
        <>
          <div className="stats">
            <div className="stat"><div className="v">{memories.length}</div><div className="k">memory entries</div></div>
            <div className="stat"><div className="v">{byNs.length}</div><div className="k">namespaces</div></div>
            <div className="stat"><div className="v">{(totalBytes / 1024).toFixed(1)}<span style={{ fontSize: 13 }}>KB</span></div><div className="k">total size</div></div>
            <div className="stat"><div className="v">k3 v1</div><div className="k">epoch (kek)</div></div>
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
