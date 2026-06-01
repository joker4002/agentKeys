import React from "react";
import { copyToClipboard } from "../lib/copy";
import type { ModuleTile, Region } from "../types";

interface Props {
  regions: Region[];
  activeRegionIds: string[];
  modules: ModuleTile[];
}

export function Legend({ regions, activeRegionIds, modules }: Props) {
  const active = new Set(activeRegionIds);
  // Build region → crate-path map from active capitals.
  const cratePathByRegion = new Map<string, string>();
  for (const m of modules) {
    if (m.isCapital) {
      cratePathByRegion.set(m.territory, m.path);
    }
  }
  const inOrder = [
    ...regions.filter((r) => active.has(r.id)),
    ...regions.filter((r) => !active.has(r.id)),
  ];
  return (
    <div className="legend">
      {inOrder.map((r) => {
        const isActive = active.has(r.id);
        const cratePath = cratePathByRegion.get(r.id);
        return (
          <button
            key={r.id}
            className="legend-row legend-row-btn"
            style={{ opacity: isActive ? 1 : 0.4 }}
            disabled={!cratePath}
            onClick={() => cratePath && void copyToClipboard(cratePath)}
            title={cratePath ?? ""}
          >
            <span
              className="legend-swatch"
              style={{
                background: isActive ? r.color : "#b9ad8e",
                borderColor: isActive ? r.ink : "#7d6f54",
              }}
            />
            <span className="legend-cn">{r.name}</span>
            {cratePath && (
              <span className="legend-en mono">{cratePath.replace(/^crates\//, "")}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
