import React, { useEffect, useState } from "react";
import { api } from "../api";
import { copyToClipboard } from "../lib/copy";
import type { Battle, BattleDetail } from "../types";

interface Props {
  battle: Battle;
  onClose: () => void;
}

export function BattleDetailModal({ battle, onClose }: Props) {
  const [detail, setDetail] = useState<BattleDetail | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setDetail(null);
    setError(null);
    api.battleDetail(battle.pid).then(setDetail).catch((e) => setError(String(e)));
  }, [battle.pid]);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  return (
    <div className="battle-modal-backdrop" onClick={onClose}>
      <div className="battle-modal" onClick={(e) => e.stopPropagation()}>
        <div className="battle-modal-header">
          <div>
            <div className="mono" style={{ fontSize: 11, opacity: 0.65 }}>pid {battle.pid}</div>
            <div style={{ fontFamily: "'Noto Serif SC', serif", fontWeight: 700, fontSize: 18 }}>
              {battle.label}
            </div>
          </div>
          <button className="panel-close" onClick={onClose}>✕</button>
        </div>

        <div className="battle-modal-body">
          {error && <div className="md-error">{error}</div>}
          {!error && detail === null && <div className="md-empty">Loading…</div>}
          {detail && !detail.exists && (
            <div className="md-error">{detail.error ?? "process not found"}</div>
          )}
          {detail && detail.exists && (
            <>
              <div className="kv-list" style={{ marginBottom: 16 }}>
                <Row k="kind" v={battle.kind} />
                <Row k="pid" v={String(detail.pid)} />
                {detail.ppid != null && <Row k="ppid" v={String(detail.ppid)} />}
                {detail.user && <Row k="user" v={detail.user} />}
                {detail.started && <Row k="started" v={detail.started} />}
                {battle.crate_name && <Row k="crate" v={battle.crate_name} />}
              </div>

              {detail.cwd && (
                <>
                  <div className="battle-modal-section-title">cwd</div>
                  <button
                    className="copy-chip"
                    onClick={() => void copyToClipboard(detail.cwd!)}
                    style={{ marginBottom: 14 }}
                  >
                    <span className="copy-chip-text">{detail.cwd}</span>
                    <span className="copy-chip-icon">⎘</span>
                  </button>
                </>
              )}

              {detail.command && (
                <>
                  <div className="battle-modal-section-title">command</div>
                  <pre
                    className="battle-modal-cmd"
                    onClick={() => void copyToClipboard(detail.command!)}
                    title="click to copy"
                  >
                    {detail.command}
                  </pre>
                </>
              )}

              <div className="battle-modal-hint">
                <kbd>esc</kbd> close · click <kbd>cwd</kbd> or <kbd>command</kbd> to copy
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="kv-row">
      <span className="kv-key">{k}</span>
      <span className="kv-val">{v}</span>
    </div>
  );
}
