import React from "react";
import type { Battle, MapData, ModuleTile } from "../types";
import { Breadcrumb, CopyChip, EmptyNote, SectionTitle, StatRow } from "./Common";

interface Props {
  data: MapData;
  mod: ModuleTile;
  battles: Battle[];
  onClose: () => void;
  onSelectModule: (id: string) => void;
}

export function ModulePanel({ data, mod, battles, onClose, onSelectModule }: Props) {
  const region = data.regions.find((r) => r.id === mod.territory);
  if (!region) return null;
  const inEdges = data.edges.filter((e) => e.to === mod.id).map((e) => e.from);
  const outEdges = data.edges.filter((e) => e.from === mod.id).map((e) => e.to);
  const battle = battles.find((b) => b.crate_name && mod.path.includes(b.crate_name));

  return (
    <aside
      className="panel"
      style={{ ["--accent" as never]: region.color, ["--accent-ink" as never]: region.ink } as React.CSSProperties}
    >
      <div className="panel-header" style={{ background: region.color }}>
        <div className="panel-territory">
          ◆ {region.name} · {region.subtitle}
        </div>
        <button className="panel-close" onClick={onClose}>
          ✕
        </button>
        <div className="panel-title-cn">{mod.cn}</div>
        <div className="panel-title-en">{mod.name}</div>
        <Breadcrumb parts={["agentKey", ...mod.path.split("/")]} />
      </div>

      <div className="panel-body">
        <p className="panel-desc">{mod.desc}</p>

        <div className="stat-grid">
          <StatRow label="Path" value={<CopyChip text={mod.path} />} />
        </div>

        {battle && (
          <>
            <SectionTitle>当前战事 · Active Battle</SectionTitle>
            <div className="battle-card">
              <div className="battle-pulse" />
              <div className="battle-info">
                <div className="battle-title">{battle.label}</div>
                <div className="battle-meta">
                  pid {battle.pid} · {battle.kind}
                </div>
              </div>
            </div>
          </>
        )}

        <SectionTitle>关系图 · Dependencies</SectionTitle>
        <div className="dep-grid">
          <div className="dep-col">
            <div className="dep-col-label">↗ depends on</div>
            {outEdges.length === 0 && <EmptyNote>none</EmptyNote>}
            {outEdges.map((id) => {
              const m = data.modules.find((x) => x.id === id);
              if (!m) return null;
              return (
                <button
                  key={id}
                  className="dep-chip"
                  onClick={() => onSelectModule(id)}
                  style={{ width: "100%", textAlign: "left", border: "1px solid rgba(0,0,0,0.1)", cursor: "pointer" }}
                >
                  {m.cn} · <span className="mono">{m.name}</span>
                </button>
              );
            })}
          </div>
          <div className="dep-col">
            <div className="dep-col-label">↙ depended on by</div>
            {inEdges.length === 0 && <EmptyNote>none</EmptyNote>}
            {inEdges.map((id) => {
              const m = data.modules.find((x) => x.id === id);
              if (!m) return null;
              return (
                <button
                  key={id}
                  className="dep-chip"
                  onClick={() => onSelectModule(id)}
                  style={{ width: "100%", textAlign: "left", border: "1px solid rgba(0,0,0,0.1)", cursor: "pointer" }}
                >
                  {m.cn} · <span className="mono">{m.name}</span>
                </button>
              );
            })}
          </div>
        </div>

        <SectionTitle>引用 · Open in LLM</SectionTitle>
        <div className="hint-row">
          <span className="hint-label">paste this into Claude / Codex Desktop</span>
          <CopyChip text={mod.path} />
        </div>
      </div>
    </aside>
  );
}
