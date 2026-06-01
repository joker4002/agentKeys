import React, { useCallback, useEffect, useMemo, useState } from "react";
import { CouncilBar } from "./components/CouncilBar";
import { HexMap } from "./components/HexMap";
import { Legend } from "./components/Legend";
import { ModulePanel } from "./components/ModulePanel";
import { CharacterPanel } from "./components/CharacterPanel";
import { WorktreeSwitcher } from "./components/WorktreeSwitcher";

const WORKTREE_KEY = "viz.worktree";

function loadWorktree(): string | null {
  try {
    const v = localStorage.getItem(WORKTREE_KEY);
    return v && v.length > 0 ? v : null;
  } catch {
    return null;
  }
}
import { MarkdownOverlay } from "./components/MarkdownOverlay";
import { BattlesDock } from "./components/BattlesDock";
import { BattleDetailModal } from "./components/BattleDetailModal";
import { loadMapData } from "./data";
import { api, battlesStream } from "./api";
import { copyToClipboard } from "./lib/copy";
import type { Battle, BattleEvent, MapData, MarkdownTab, Selection } from "./types";

export function App() {
  const [data, setData] = useState<MapData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Selection>(null);
  const [hoverModule, setHoverModule] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [battles, setBattles] = useState<Battle[]>([]);
  const [dockOpen, setDockOpen] = useState(true);
  const [generated] = useState(() => new Date().toISOString());

  // Markdown tabs (chrome-style fullscreen overlay).
  const [tabs, setTabs] = useState<MarkdownTab[]>([]);
  const [activeTab, setActiveTab] = useState(0);
  const [overview, setOverview] = useState(false);
  const [overlayMinimized, setOverlayMinimized] = useState(false);
  const [activeBattle, setActiveBattle] = useState<Battle | null>(null);
  const [worktree, setWorktreeState] = useState<string | null>(loadWorktree);

  const setWorktree = (path: string | null) => {
    setWorktreeState(path);
    try {
      if (path) localStorage.setItem(WORKTREE_KEY, path);
      else localStorage.removeItem(WORKTREE_KEY);
    } catch {
      // ignore
    }
  };

  useEffect(() => {
    loadMapData().then(setData).catch((e) => setError(String(e)));
  }, []);

  useEffect(() => {
    const es = battlesStream((raw) => {
      const ev = raw as BattleEvent;
      if (ev.type === "snapshot") setBattles(ev.battles);
      else setBattles(ev.current);
    });
    return () => es.close();
  }, []);

  const fetchMarkdownInto = useCallback(async (noLine: string) => {
    try {
      const detail = await api.markdown(noLine);
      setTabs((prev) =>
        prev.map((t) =>
          t.path === noLine
            ? { ...t, body: detail.error ? null : detail.raw_markdown, error: detail.error }
            : t,
        ),
      );
    } catch (e) {
      setTabs((prev) =>
        prev.map((t) => (t.path === noLine ? { ...t, error: String(e) } : t)),
      );
    }
  }, []);

  const openMarkdown = useCallback(
    async (path: string) => {
      const noLine = path.replace(/:\d+$/, "");
      setOverlayMinimized(false);
      setTabs((prev) => {
        const existing = prev.findIndex((t) => t.path === noLine);
        if (existing >= 0) {
          setActiveTab(existing);
          setOverview(false);
          // Force a body refresh so VS Code edits show up. Mark body=null so
          // the overlay shows the loading state while the fetch resolves.
          return prev.map((t, i) => (i === existing ? { ...t, body: null, error: null } : t));
        }
        const title = noLine.split("/").pop() ?? noLine;
        const next: MarkdownTab[] = [...prev, { path: noLine, title, body: null, error: null }];
        setActiveTab(next.length - 1);
        setOverview(false);
        return next;
      });
      await fetchMarkdownInto(noLine);
    },
    [fetchMarkdownInto],
  );

  const refreshActiveMarkdown = useCallback(() => {
    const t = tabs[activeTab];
    if (!t) return;
    setTabs((prev) =>
      prev.map((x, i) => (i === activeTab ? { ...x, body: null, error: null } : x)),
    );
    void fetchMarkdownInto(t.path);
  }, [tabs, activeTab, fetchMarkdownInto]);

  const closeTab = useCallback(
    (idx: number) => {
      setTabs((prev) => {
        const next = prev.filter((_, i) => i !== idx);
        if (next.length === 0) {
          setOverview(false);
          setActiveTab(0);
        } else {
          setActiveTab((cur) => Math.max(0, Math.min(next.length - 1, idx <= cur ? cur - 1 : cur)));
        }
        return next;
      });
    },
    [],
  );

  const closeAllTabs = useCallback(() => {
    setTabs([]);
    setOverview(false);
    setActiveTab(0);
  }, []);

  // Delegated copy-pill / md-open click handler.
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      const target = e.target as HTMLElement | null;
      if (!target) return;
      // Inner copy-pill or VS Code button takes precedence over an outer
      // [data-md-open] row — they have their own action.
      const pill = target.closest(".copy-pill") as HTMLButtonElement | null;
      if (pill) {
        e.preventDefault();
        e.stopPropagation();
        const ref = pill.dataset.ref ?? "";
        const action = pill.dataset.action ?? "copy";
        if (action === "open" && ref) {
          void openMarkdown(ref);
        } else if (ref) {
          void copyToClipboard(ref);
        }
        return;
      }
      const codeBtn = target.closest(".md-code-copy") as HTMLButtonElement | null;
      if (codeBtn) {
        e.preventDefault();
        e.stopPropagation();
        const code = codeBtn.dataset.code ?? "";
        if (code) {
          void copyToClipboard(code).then(() => {
            codeBtn.classList.add("is-copied");
            window.setTimeout(() => codeBtn.classList.remove("is-copied"), 1100);
          });
        }
        return;
      }
      if (target.closest(".vscode-btn")) return; // let the <a> follow vscode://
      const opener = target.closest("[data-md-open]") as HTMLElement | null;
      if (opener) {
        const path = opener.dataset.mdOpen;
        if (path) {
          e.preventDefault();
          e.stopPropagation();
          void openMarkdown(path);
        }
      }
    };
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, [openMarkdown]);

  // Keyboard shortcuts: esc / tab / cmd-w / arrows.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const inInput = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA");

      // ESC: if the markdown overlay is up, minimize (don't close tabs).
      // Otherwise close side panels. Tabs persist until cmd-w / Close all.
      if (e.key === "Escape") {
        if (tabs.length > 0 && !overlayMinimized) {
          if (overview) {
            setOverview(false);
            return;
          }
          setOverlayMinimized(true);
          return;
        }
        if (selected) {
          setSelected(null);
          return;
        }
      }

      // Number hotkeys: 1..9 select the Nth character (council chip order).
      // Active in any state except when typing in an input. If the markdown
      // overlay is minimized, this also restores it so previously-opened docs
      // reappear immediately.
      if (
        !inInput &&
        !e.metaKey &&
        !e.ctrlKey &&
        !e.altKey &&
        /^[1-9]$/.test(e.key) &&
        data
      ) {
        const idx = parseInt(e.key, 10) - 1;
        const c = data.characters[idx];
        if (c) {
          e.preventDefault();
          setSelected({ kind: "character", id: c.id });
          if (c.id === "zhugeliang" && tabs.length > 0) setOverlayMinimized(false);
          return;
        }
      }

      // Overlay-only shortcuts (Tab / arrows / cmd-w) — only when the overlay
      // is actually visible.
      const overlayHidden = tabs.length === 0 || overlayMinimized;
      if (overlayHidden || inInput) return;

      // Tab toggles overview (only when overlay is up).
      if (e.key === "Tab" && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        setOverview((v) => !v);
        return;
      }
      // cmd/ctrl-w closes the active tab.
      if (e.key === "w" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        closeTab(activeTab);
        return;
      }
      // cmd/ctrl-r reloads the active tab from disk.
      if (e.key === "r" && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
        e.preventDefault();
        refreshActiveMarkdown();
        return;
      }
      // Arrow keys switch tabs (when not in overview).
      if (!overview) {
        if (e.key === "ArrowRight" && tabs.length > 1) {
          setActiveTab((i) => (i + 1) % tabs.length);
        } else if (e.key === "ArrowLeft" && tabs.length > 1) {
          setActiveTab((i) => (i - 1 + tabs.length) % tabs.length);
        }
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [tabs, activeTab, overview, overlayMinimized, selected, closeTab, data, refreshActiveMarkdown]);

  const selectModule = (id: string) => setSelected({ kind: "module", id });
  const selectCharacter = (id: string) => {
    setSelected({ kind: "character", id });
    // Only 诸葛亮 (docs) auto-restores the markdown overlay — that's the
    // character whose primary surface is markdown files.
    if (id === "zhugeliang" && tabs.length > 0) setOverlayMinimized(false);
  };
  const close = () => setSelected(null);

  const matchSet = useMemo(() => {
    if (!data || !filter.trim()) return null;
    const q = filter.toLowerCase();
    const set = new Set<string>();
    data.modules.forEach((m) => {
      if (
        m.name.toLowerCase().includes(q) ||
        m.cn.includes(filter) ||
        m.path.toLowerCase().includes(q) ||
        m.desc.toLowerCase().includes(q)
      ) {
        set.add(m.id);
      }
    });
    return set;
  }, [filter, data]);

  if (error) {
    return (
      <div className="app">
        <header className="topbar">
          <div className="topbar-brand">
            <div className="brand-text">
              <div className="brand-title">agentKey · 蜀汉地图</div>
              <div className="brand-sub">backend offline</div>
            </div>
          </div>
        </header>
        <div style={{ padding: 32 }}>
          <div className="md-error">
            backend unreachable: {error}
            <br />
            run <code>cargo run --release</code> in <code>viz/server/</code>
          </div>
        </div>
      </div>
    );
  }

  if (!data) {
    return (
      <div className="app">
        <header className="topbar">
          <div className="topbar-brand">
            <div className="brand-text">
              <div className="brand-title">agentKey · 蜀汉地图</div>
              <div className="brand-sub">loading…</div>
            </div>
          </div>
        </header>
      </div>
    );
  }

  const selectedModule =
    selected?.kind === "module" ? data.modules.find((m) => m.id === selected.id) ?? null : null;
  const selectedCharacter =
    selected?.kind === "character"
      ? data.characters.find((c) => c.id === selected.id) ?? null
      : null;

  return (
    <div className="app">
      <header className="topbar">
        <div className="topbar-brand">
          <div className="brand-mark">
            <svg width="32" height="32" viewBox="0 0 32 32">
              <polygon
                points="16,2 30,10 30,22 16,30 2,22 2,10"
                fill="#D9534F"
                stroke="#7A2E1E"
                strokeWidth="2"
              />
              <text
                x="16"
                y="21"
                textAnchor="middle"
                fontFamily="'Noto Serif SC', serif"
                fontWeight="700"
                fontSize="14"
                fill="#fdfaf0"
              >
                蜀
              </text>
            </svg>
          </div>
          <div className="brand-text">
            <div className="brand-title">agentKey · 蜀汉地图</div>
            <div className="brand-sub">
              codebase atlas · <span className="mono">agentkeys</span> · {data.regions.length} regions
              · {data.modules.length} towns
            </div>
          </div>
        </div>
        <div className="topbar-search">
          <input
            placeholder="搜索 · search regions, towns, paths…"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
          {filter && (
            <button className="search-clear" onClick={() => setFilter("")}>
              ✕
            </button>
          )}
        </div>
        <div className="topbar-meta">
          <WorktreeSwitcher selected={worktree} onChange={setWorktree} />
          <span className="meta-item">
            <span className="meta-label">generated</span>{" "}
            <span className="mono">{generated.slice(0, 16).replace("T", " ")}</span>
          </span>
          <button
            className="rebuild-btn"
            onClick={() =>
              alert(
                "Run /agentkeys-viz-sync in Claude Desktop to regenerate viz/web/public/map-layout.json",
              )
            }
          >
            ⟳ Rebuild
          </button>
        </div>
      </header>

      <CouncilBar
        characters={data.characters}
        selectedId={selected?.kind === "character" ? selected.id : null}
        onSelect={selectCharacter}
      />

      <div className={`main ${selectedCharacter ? "main-character" : ""}`}>
        {selectedCharacter ? (
          <CharacterPanel
            data={data}
            char={selectedCharacter}
            onClose={close}
            onSelectModule={selectModule}
            worktree={worktree}
          />
        ) : (
          <>
            <aside className="left">
              <Legend
                regions={data.regions}
                activeRegionIds={data.activeRegionIds}
                modules={data.modules}
              />
            </aside>

            <div className="map-wrap" onClick={close}>
              {matchSet && matchSet.size > 0 && (
                <div className="search-result-banner">
                  {matchSet.size} match{matchSet.size === 1 ? "" : "es"} · click a highlighted hex
                </div>
              )}
              <HexMap
                data={data}
                battles={battles}
                selected={selected}
                hoverModule={hoverModule}
                setHoverModule={setHoverModule}
                onSelectModule={selectModule}
                matchSet={matchSet}
              />
            </div>

            {selectedModule && (
              <ModulePanel
                data={data}
                mod={selectedModule}
                battles={battles}
                onClose={close}
                onSelectModule={selectModule}
              />
            )}
          </>
        )}
      </div>

      <BattlesDock
        battles={battles}
        open={dockOpen}
        onToggle={() => setDockOpen(!dockOpen)}
        onSelectBattle={setActiveBattle}
      />

      {activeBattle && (
        <BattleDetailModal battle={activeBattle} onClose={() => setActiveBattle(null)} />
      )}

      {tabs.length > 0 && (
        <MarkdownOverlay
          tabs={tabs}
          activeIdx={activeTab}
          overview={overview}
          minimized={overlayMinimized}
          onSwitch={(i) => {
            setActiveTab(i);
            setOverview(false);
          }}
          onCloseTab={closeTab}
          onCloseAll={closeAllTabs}
          onOverview={() => setOverview((v) => !v)}
          onOpenFromOverview={(i) => {
            setActiveTab(i);
            setOverview(false);
          }}
          onRefreshActive={refreshActiveMarkdown}
        />
      )}
      {overlayMinimized && tabs.length > 0 && (
        <button
          className="md-restore"
          onClick={() => setOverlayMinimized(false)}
          title={`Restore markdown view (${tabs.length} tab${tabs.length === 1 ? "" : "s"})`}
        >
          <span className="md-restore-glyph">▤</span>
          <span className="md-restore-count">{tabs.length}</span>
        </button>
      )}
    </div>
  );
}
