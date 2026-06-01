import React from "react";
import type { Battle } from "../types";

interface Props {
  battles: Battle[];
  open: boolean;
  onToggle: () => void;
  onSelectBattle: (b: Battle) => void;
}

export function BattlesDock({ battles, open, onToggle, onSelectBattle }: Props) {
  return (
    <div className={`dock ${open ? "is-open" : ""}`}>
      <button className="dock-tab" onClick={onToggle}>
        <span className="dock-tab-pulse" />
        <span className="dock-tab-label">
          {open ? "▾" : "▴"} 当前战事 · {battles.length}
        </span>
      </button>
      {open && (
        <div className="dock-body">
          {battles.length === 0 && (
            <div style={{ color: "rgba(253,250,240,0.5)", fontSize: 12, padding: "8px 12px" }}>
              No active battles.
            </div>
          )}
          {battles.map((b) => (
            <button
              key={b.pid}
              className="battle-dock-card battle-running"
              onClick={() => onSelectBattle(b)}
              title="click for thread detail"
            >
              <div
                className="battle-dock-char"
                style={{ borderColor: kindColor(b.kind), color: kindColor(b.kind) }}
              >
                {kindGlyph(b.kind)}
              </div>
              <div className="battle-dock-body">
                <div className="battle-dock-title">
                  {b.label}
                  <span className="battle-dock-live">● LIVE</span>
                </div>
                <div className="battle-dock-meta">
                  <span>pid {b.pid}</span>
                  {b.crate_name && (
                    <>
                      <span>·</span>
                      <span className="mono">{b.crate_name}</span>
                    </>
                  )}
                </div>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function kindColor(kind: Battle["kind"]): string {
  switch (kind) {
    case "cargotest":
      return "#3A7BC8";
    case "claude":
      return "#7B5FB8";
    case "codex":
      return "#3F8C5C";
    case "ralph":
      return "#7A2E1E";
    case "provisioner":
      return "#C9842F";
    default:
      return "#5b4a32";
  }
}

function kindGlyph(kind: Battle["kind"]): string {
  switch (kind) {
    case "cargotest":
      return "云";
    case "claude":
      return "亮";
    case "codex":
      return "正";
    case "ralph":
      return "飞";
    case "provisioner":
      return "统";
    default:
      return "?";
  }
}
