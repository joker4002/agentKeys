import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { Worktree } from "../types";

interface Props {
  selected: string | null; // null = use backend's default repo
  onChange: (path: string | null) => void;
}

export function WorktreeSwitcher({ selected, onChange }: Props) {
  const [open, setOpen] = useState(false);
  const [worktrees, setWorktrees] = useState<Worktree[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const wrapRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    api
      .worktrees()
      .then((p) => {
        setWorktrees(p.worktrees);
        if (p.error) setError(p.error);
      })
      .catch((e) => setError(String(e)));
  }, []);

  // Close on click outside.
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (!wrapRef.current) return;
      if (!wrapRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  const current =
    worktrees?.find((w) => w.path === selected) ??
    (selected ? null : worktrees?.[0]) ??
    null;

  return (
    <div ref={wrapRef} className="wtsw">
      <button
        className="wtsw-btn"
        onClick={() => setOpen((v) => !v)}
        title="Switch repo / worktree for the docs view"
      >
        <span className="wtsw-icon">⎇</span>
        <span className="wtsw-label">{current?.label ?? "default"}</span>
        <span className="wtsw-caret">▾</span>
      </button>
      {open && (
        <div className="wtsw-menu">
          <div className="wtsw-menu-title">Switch worktree</div>
          {error && <div className="wtsw-error">{error}</div>}
          {worktrees === null && <div className="wtsw-empty">Loading…</div>}
          {worktrees && worktrees.length === 0 && (
            <div className="wtsw-empty">No worktrees found</div>
          )}
          {worktrees?.map((w) => {
            const active = (selected ?? worktrees[0]?.path) === w.path;
            return (
              <button
                key={w.path}
                className={`wtsw-item ${active ? "is-active" : ""}`}
                onClick={() => {
                  onChange(w.path);
                  setOpen(false);
                }}
                title={w.path}
              >
                <span className="wtsw-item-label">
                  {w.label}
                  {w.is_main && <span className="wtsw-badge">main</span>}
                  {w.is_detached && <span className="wtsw-badge wtsw-badge-warn">detached</span>}
                </span>
                <span className="wtsw-item-path">{shortPath(w.path)}</span>
                {w.contained_in.length > 0 && (
                  <span className="wtsw-item-branches">
                    {w.contained_in.slice(0, 4).map((b) => (
                      <span
                        key={b}
                        className={`wtsw-branch-chip ${b.startsWith("claude/") ? "is-muted" : ""} ${
                          b.startsWith("origin/") || b.startsWith("remotes/") ? "is-remote" : ""
                        }`}
                      >
                        {b}
                      </span>
                    ))}
                    {w.contained_in.length > 4 && (
                      <span className="wtsw-branch-chip is-muted">
                        +{w.contained_in.length - 4}
                      </span>
                    )}
                  </span>
                )}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function shortPath(p: string): string {
  // Collapse the user's home dir to ~, drop the leading worktrees prefix.
  const home = "/Users/agent-jojo";
  let s = p.startsWith(home) ? "~" + p.slice(home.length) : p;
  s = s.replace(/^~\/Projects\//i, "~/.../");
  return s;
}
