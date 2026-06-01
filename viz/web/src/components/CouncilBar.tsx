import React from "react";
import type { Character } from "../types";

interface Props {
  characters: Character[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}

export function CouncilBar({ characters, selectedId, onSelect }: Props) {
  return (
    <div className="council">
      <div className="council-list">
        {characters.map((c, idx) => {
          const num = idx + 1;
          return (
            <button
              key={c.id}
              className={`council-chip ${selectedId === c.id ? "is-active" : ""}`}
              style={{ ["--c" as never]: c.color }}
              onClick={() => onSelect(c.id)}
              title={`${c.name} · press ${num}`}
            >
              <span className="council-num" aria-hidden>{num}</span>
              <span className="council-avatar">{c.name[0]}</span>
              <span className="council-text">
                <span className="council-name">{c.name}</span>
                <span className="council-role mono">
                  {c.endpoint.replace(/^\/api\//, "")}
                </span>
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
