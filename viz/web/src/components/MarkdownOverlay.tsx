import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { MarkdownTab } from "../types";
import { extractToc, renderMarkdown } from "../lib/markdown";
import { copyToClipboard } from "../lib/copy";

const TEXT_SIZE_KEY = "viz.md.textSize";
type TextSize = "s" | "m" | "l" | "xl" | "xxl";
const TEXT_SIZES: { id: TextSize; label: string }[] = [
  { id: "s", label: "A" },
  { id: "m", label: "A" },
  { id: "l", label: "A" },
  { id: "xl", label: "A" },
  { id: "xxl", label: "A" },
];

function loadTextSize(): TextSize {
  try {
    const v = localStorage.getItem(TEXT_SIZE_KEY) as TextSize | null;
    if (v && ["s", "m", "l", "xl", "xxl"].includes(v)) return v;
  } catch {
    // localStorage unavailable
  }
  return "m";
}

interface Props {
  tabs: MarkdownTab[];
  activeIdx: number;
  onSwitch: (idx: number) => void;
  onCloseTab: (idx: number) => void;
  onCloseAll: () => void;
  onOverview: () => void;
  overview: boolean;
  onOpenFromOverview: (idx: number) => void;
  minimized: boolean;
  onRefreshActive: () => void;
}

export function MarkdownOverlay({
  tabs,
  activeIdx,
  onSwitch,
  onCloseTab,
  onCloseAll,
  onOverview,
  overview,
  onOpenFromOverview,
  minimized,
  onRefreshActive,
}: Props) {
  if (tabs.length === 0) return null;
  const active = tabs[activeIdx];

  const toc = useMemo(() => (active.body ? extractToc(active.body) : []), [active.body]);
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const [textSize, setTextSize] = useState<TextSize>(loadTextSize);

  useEffect(() => {
    try {
      localStorage.setItem(TEXT_SIZE_KEY, textSize);
    } catch {
      // ignore
    }
  }, [textSize]);

  // Per-tab scroll position memory. Saved on every scroll, restored on every
  // tab switch (and after the body finishes loading).
  const scrollByPath = useRef<Map<string, number>>(new Map());
  const onBodyScroll = (e: React.UIEvent<HTMLDivElement>) => {
    if (overview || minimized) return;
    scrollByPath.current.set(active.path, (e.target as HTMLDivElement).scrollTop);
  };
  useLayoutEffect(() => {
    if (overview || minimized) return;
    if (!bodyRef.current) return;
    bodyRef.current.scrollTop = scrollByPath.current.get(active.path) ?? 0;
  }, [active.path, active.body, overview, minimized]);

  const scrollTo = (id: string) => {
    if (!bodyRef.current) return;
    const el = bodyRef.current.querySelector<HTMLElement>(`#${CSS.escape(id)}`);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  return (
    <div
      className="md-overlay"
      onClick={(e) => e.stopPropagation()}
      style={minimized ? { display: "none" } : undefined}
    >
      <aside className="md-side">
        <div className="md-side-actions">
          <button
            className={`md-overview-btn ${overview ? "is-active" : ""}`}
            onClick={onOverview}
            title="Overview (Tab)"
          >
            ▦ Overview
          </button>
          <button className="md-close-all" onClick={onCloseAll} title="Close all">
            ✕ Close all
          </button>
        </div>
        <div className="md-size-picker">
          <span className="md-size-picker-label">Aa</span>
          {TEXT_SIZES.map((sz) => (
            <button
              key={sz.id}
              className={`md-size-btn md-size-btn-${sz.id} ${textSize === sz.id ? "is-active" : ""}`}
              onClick={() => setTextSize(sz.id)}
              title={`Text size · ${sz.id.toUpperCase()}`}
              aria-pressed={textSize === sz.id}
            >
              {sz.label}
            </button>
          ))}
        </div>

        {/* Active-file controls — reload + copy path. */}
        {!overview && (
          <div className="md-side-file">
            <button
              className="md-refresh-btn"
              onClick={onRefreshActive}
              title="Reload from disk (cmd-r)"
              aria-label="Reload"
            >
              ↻
            </button>
            <button
              className="copy-chip md-side-file-path"
              onClick={() => void copyToClipboard(active.path)}
              title={`Copy full path · ${active.path}`}
            >
              <span className="copy-chip-text">{active.path}</span>
              <span className="copy-chip-icon">⎘</span>
            </button>
          </div>
        )}

        {/* Compact tab strip — switch between open docs. */}
        <div className="md-side-tabs">
          {tabs.map((t, i) => (
            <div
              key={t.path}
              className={`md-side-tab ${i === activeIdx && !overview ? "is-active" : ""}`}
              onClick={() => onSwitch(i)}
              title={t.path}
            >
              <span className="md-side-tab-title">{t.title}</span>
              <button
                className="md-tab-close"
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab(i);
                }}
                title="Close tab (cmd-w)"
              >
                ✕
              </button>
            </div>
          ))}
        </div>

        {/* Navigation menu / table of contents for the active document. */}
        {!overview && (
          <div className="md-toc">
            <div className="md-toc-title">目录 · Navigation</div>
            {toc.length === 0 ? (
              <div className="md-toc-empty">no headings</div>
            ) : (
              <ul className="md-toc-list">
                {toc.map((h, i) => (
                  <li
                    key={`${h.id}-${i}`}
                    className={`md-toc-item md-toc-h${h.level}`}
                    onClick={() => scrollTo(h.id)}
                    title={h.text}
                  >
                    {h.text}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        <div className="md-side-hint">
          <kbd>esc</kbd> minimize · <kbd>cmd-w</kbd> close · <kbd>tab</kbd> overview · <kbd>← →</kbd> switch
        </div>
      </aside>

      <div className="md-overlay-body" ref={bodyRef} onScroll={onBodyScroll}>
        {overview ? (
          <div className="md-overview-grid">
            {tabs.map((t, i) => (
              <div
                key={t.path}
                className="md-overview-card"
                onClick={() => onOpenFromOverview(i)}
                title={t.path}
              >
                <div className="md-overview-card-title">{t.title}</div>
                <div className="md-overview-card-path">
                  <button
                    className="copy-pill"
                    onClick={(e) => {
                      e.stopPropagation();
                      void copyToClipboard(t.path);
                    }}
                  >
                    {t.path}
                  </button>
                </div>
                <div className="md-overview-card-preview">
                  {t.body ? (
                    excerpt(t.body)
                  ) : t.error ? (
                    <span style={{ color: "#B83A3A" }}>{t.error}</span>
                  ) : (
                    "Loading…"
                  )}
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="md-page">
            <div className="md-page-header">
              <div className="md-page-breadcrumb">
                {active.path.split("/").map((p, i, arr) => (
                  <React.Fragment key={i}>
                    {i > 0 && <span className="breadcrumb-sep">›</span>}
                    <span className={i === arr.length - 1 ? "breadcrumb-here" : ""}>{p}</span>
                  </React.Fragment>
                ))}
              </div>
            </div>
            {active.error && <div className="md-error">{active.error}</div>}
            {!active.error && active.body === null && <div className="md-empty">Loading…</div>}
            {!active.error && active.body !== null && (
              <div
                className={`md-view markdown size-${textSize}`}
                dangerouslySetInnerHTML={{ __html: renderMarkdown(active.body) }}
              />
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function excerpt(s: string): string {
  return s
    .replace(/^---[\s\S]*?---\s*/m, "")
    .replace(/[#*`_>]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 220);
}

