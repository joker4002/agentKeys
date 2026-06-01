import React, { useEffect, useState } from "react";
import { api } from "../api";
import type {
  Character,
  CloudSettingsPayload,
  ClaudePlansPayload,
  DocsPayload,
  EnvSettingsPayload,
  GhPayload,
  MapData,
  PlanSummary,
  PlansPayload,
  ScriptsPayload,
  TestsPayload,
} from "../types";
import { CopyChip, EmptyNote, SectionTitle } from "./Common";
import { JjBody } from "./JjBody";

// ─── reusable bits ───
function CharTabs({
  tabs,
  active,
  onChange,
}: {
  tabs: { id: string; label: string; count?: number; dim?: boolean }[];
  active: string;
  onChange: (id: string) => void;
}) {
  return (
    <div className="char-tabs">
      {tabs.map((t) => (
        <button
          key={t.id}
          className={`char-tab ${active === t.id ? "is-active" : ""}`}
          onClick={() => onChange(t.id)}
          style={t.dim && active !== t.id ? { opacity: 0.55 } : undefined}
        >
          {t.label}
          {t.count != null && <span className="char-tab-count">{t.count}</span>}
        </button>
      ))}
    </div>
  );
}

function VSCodeBtn({ path }: { path: string }) {
  const url = `vscode://file${path.startsWith("/") ? "" : "/"}${path}`;
  return (
    <a
      className="vscode-btn"
      href={url}
      title={`open in VS Code: ${path}`}
      aria-label="open in VS Code"
    />
  );
}

interface Props {
  data: MapData;
  char: Character;
  onClose: () => void;
  onSelectModule: (id: string) => void;
  worktree?: string | null;
}

export function CharacterPanel({ char, onClose, worktree = null }: Props) {
  return (
    <aside
      className="panel panel-char"
      style={{ ["--accent" as never]: char.color, ["--accent-ink" as never]: char.color } as React.CSSProperties}
    >
      <div className="panel-header char-header" style={{ background: char.color }}>
        <button className="panel-close" onClick={onClose}>
          ✕
        </button>
        <div className="char-portrait">
          <div className="char-portrait-circle">{char.name[0]}</div>
        </div>
        <div className="char-meta">
          <div className="char-name">{char.name}</div>
          <div className="char-title mono" style={{ opacity: 0.85 }}>
            {char.endpoint.replace(/^\/api\//, "")}
          </div>
        </div>
      </div>

      <div className="panel-body">
        {char.id === "zhugeliang" && <DocsBody worktree={worktree} />}
        {char.id === "liubei" && <ClaudePlansBody />}
        {char.id === "zhangfei" && <ScriptsBody worktree={worktree} />}
        {char.id === "zhaoyun" && <TestsBody />}
        {char.id === "machao" && <GhBody />}
        {char.id === "huangzhong" && <CloudBody />}
        {char.id === "guanyu" && <EnvBody />}
        {char.id === "fazheng" && <JjBody />}
        {char.id === "weiyan" && <PlansBody kind="eng" />}
      </div>
    </aside>
  );
}

// ─── 法正 (CEO) / 魏延 (eng) — plans ───
function PlansBody({ kind }: { kind: "ceo" | "eng" }) {
  const [data, setData] = useState<PlansPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    api.plans(kind).then(setData).catch((e) => setErr(String(e)));
  }, [kind]);

  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  if (data.error && data.plans.length === 0) {
    return <EmptyNote>{data.error}</EmptyNote>;
  }
  if (data.plans.length === 0) {
    return (
      <div className="empty-note" style={{ padding: 20, textAlign: "center" }}>
        没有谋划记录 · No {kind} plans yet. Run <code className="mono">/plan-{kind}-review</code> in
        Claude Desktop.
      </div>
    );
  }

  return (
    <>
      <SectionTitle count={data.plans.length}>谋划记录 · gstack {kind} plans</SectionTitle>
      <div className="plan-list">
        {data.plans.map((p) => (
          <div
            key={p.path}
            className="plan-row"
            style={{ cursor: "pointer" }}
            data-md-open={p.path}
            title="open in fullscreen"
          >
            <PlanRowHeader p={p} />
            <div className="plan-title">{p.title ?? p.slug}</div>
            <div className="plan-meta">
              <CopyChip text={p.path} />
              <VSCodeBtn path={p.path} />
            </div>
          </div>
        ))}
      </div>
    </>
  );
}

function PlanRowHeader({ p }: { p: PlanSummary }) {
  const date = p.mtime_unix ? new Date(p.mtime_unix * 1000).toISOString().slice(0, 10) : "";
  const status = p.kind === "unknown" ? "in-progress" : "approved";
  return (
    <div className="plan-head">
      <span className={`plan-status plan-${status}`}>{p.kind}</span>
      <span className="plan-id">{p.slug.slice(0, 28)}</span>
      <span className="plan-date">{date}</span>
    </div>
  );
}

// ─── 诸葛亮 — docs entry ───
// Pinned single-source-of-truth doc (arch.md = technical, agent-iam-strategy.md
// = product). Always rendered above the tabs, on every tab.
function PinnedDoc({ node }: { node: import("../types").DocsNode }) {
  const isProduct = node.index_caption?.startsWith("product");
  return (
    <div
      className="file-row"
      style={{
        marginBottom: 8,
        padding: "8px 10px",
        borderLeft: "3px solid var(--accent)",
        background: "var(--panel-tint, rgba(63,140,92,0.08))",
      }}
      title={node.index_caption ?? "single source of truth"}
    >
      <div className="file-row-main">
        <span aria-hidden>{isProduct ? "🧭" : "🌟"}</span>{" "}
        <button
          className="copy-pill"
          data-ref={node.path}
          data-action="open"
          style={{ display: "inline-flex", fontWeight: 600 }}
        >
          {node.name}
        </button>
        <VSCodeBtn path={node.path} />
        {node.line_count !== undefined && (
          <span className="file-row-loc">{node.line_count} lines</span>
        )}
      </div>
      {node.index_caption && (
        <div style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 3 }}>
          {node.index_caption}
        </div>
      )}
    </div>
  );
}

function DocsBody({ worktree }: { worktree: string | null }) {
  const [data, setData] = useState<DocsPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  // Main page = root docs only; each subfolder is its own tab.
  const [tab, setTab] = useState<string>("__root");
  const [reloadKey, setReloadKey] = useState(0);
  const refresh = () => setReloadKey((k) => k + 1);
  useEffect(() => {
    setData(null);
    setErr(null);
    api.docs(worktree ?? undefined).then(setData).catch((e) => setErr(String(e)));
  }, [worktree, reloadKey]);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  if (data.error) return <EmptyNote>{data.error}</EmptyNote>;

  // arch.md + agent-iam-strategy.md, already in display order from the server.
  const pinned = data.tree.filter((n) => n.is_index);
  const rootFiles = data.tree.filter((n) => !n.is_dir && !n.is_index);
  const dirsRaw = data.tree.filter((n) => n.is_dir);
  // Subfolders become tabs; archived is de-emphasized and pushed to the end.
  const dirs = [
    ...dirsRaw.filter((d) => d.name !== "archived"),
    ...dirsRaw.filter((d) => d.name === "archived"),
  ];

  const tabs = [
    { id: "__root", label: "docs/", count: pinned.length + rootFiles.length },
    ...dirs.map((d) => ({
      id: d.path,
      label: d.name,
      count: d.entry_count ?? d.children?.length ?? 0,
      dim: d.name === "archived",
    })),
  ];

  const activeDir = dirs.find((d) => d.path === tab);
  // Collapsed dirs (archived/) carry entry_count instead of children.
  const collapsedCount = activeDir?.entry_count;

  return (
    <>
      {pinned.map((n) => (
        <PinnedDoc key={n.path} node={n} />
      ))}
      <CharTabs tabs={tabs} active={tab} onChange={setTab} />
      {activeDir?.audience && (
        <p
          style={{
            fontSize: 11,
            color: "var(--ink-faint)",
            margin: "0 0 8px",
            fontStyle: "italic",
          }}
        >
          audience: {activeDir.audience}
        </p>
      )}
      <p style={{ fontSize: 11, color: "var(--ink-faint)", margin: "0 0 10px", display: "flex", alignItems: "center", gap: 6 }}>
        <button className="md-refresh-btn" onClick={refresh} title="Re-scan docs/ from disk" aria-label="Refresh docs">
          ↻
        </button>
        Root <CopyChip text={data.root} /> <VSCodeBtn path={data.root} />
      </p>
      {tab === "__root" ? (
        <DocsTree nodes={rootFiles} />
      ) : collapsedCount != null ? (
        <EmptyNote>
          {collapsedCount} file{collapsedCount === 1 ? "" : "s"} — collapsed.
          {activeDir?.audience ? ` ${activeDir.audience}.` : ""}{" "}
          <CopyChip text={activeDir!.path} /> <VSCodeBtn path={activeDir!.path} />
        </EmptyNote>
      ) : (
        <DocsTree nodes={activeDir?.children ?? []} />
      )}
    </>
  );
}

function DocsTree({ nodes, depth = 0 }: { nodes: import("../types").DocsNode[]; depth?: number }) {
  return (
    <div style={{ paddingLeft: depth * 14 }}>
      {nodes.map((n) => (
        <div key={n.path}>
          <div
            className="file-row"
            style={{
              marginBottom: 4,
              padding: "6px 10px",
              ...(n.is_index
                ? { borderLeft: "3px solid var(--accent)", fontWeight: 600 }
                : {}),
            }}
            title={n.audience ?? undefined}
          >
            <div className="file-row-main">
              {n.is_index ? "🌟" : n.is_dir ? "📁" : "📄"}{" "}
              <button
                className="copy-pill"
                data-ref={n.path}
                data-action={n.path.toLowerCase().endsWith(".md") ? "open" : "copy"}
                style={{ display: "inline-flex" }}
              >
                {n.name}
              </button>
              {!n.is_dir && <VSCodeBtn path={n.path} />}
              {n.line_count !== undefined && (
                <span className="file-row-loc">{n.line_count} lines</span>
              )}
              {n.audience && (
                <span
                  className="file-row-loc"
                  style={{ fontStyle: "italic", opacity: 0.75 }}
                >
                  {n.audience}
                </span>
              )}
            </div>
          </div>
          {n.children && n.children.length > 0 && <DocsTree nodes={n.children} depth={depth + 1} />}
        </div>
      ))}
    </div>
  );
}

// ─── 法正 — ~/.claude/plans (Global) + project .claude/plans (Project) ───
function ClaudePlansBody() {
  const [data, setData] = useState<ClaudePlansPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<string>("__all");
  useEffect(() => {
    api.claudePlans().then(setData).catch((e) => setErr(String(e)));
  }, []);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  const sections = data.sections ?? [];
  const tabs = [
    { id: "__all", label: "All", count: data.plans.length },
    ...sections.map((s, i) => ({
      id: `s${i}`,
      label: s.label.replace(/^.*?· /, ""),
      count: s.plans.length,
    })),
  ];
  const visible: PlanSummary[] =
    tab === "__all"
      ? data.plans
      : sections[parseInt(tab.slice(1), 10)]?.plans ?? [];
  const sectionForTab =
    tab === "__all" ? null : sections[parseInt(tab.slice(1), 10)] ?? null;

  return (
    <>
      <CharTabs tabs={tabs} active={tab} onChange={setTab} />
      {sectionForTab && (
        <p style={{ fontSize: 11, color: "var(--ink-faint)", margin: "0 0 10px" }}>
          {sectionForTab.exists ? "Directory" : "Not found"}: <CopyChip text={sectionForTab.dir} />{" "}
          {sectionForTab.exists && <VSCodeBtn path={sectionForTab.dir} />}
        </p>
      )}
      {visible.length === 0 && <EmptyNote>none</EmptyNote>}
      <div className="plan-list">
        {visible.map((p) => (
          <div
            key={`${p.path}`}
            className="plan-row"
            style={{ cursor: "pointer" }}
            data-md-open={p.path}
            title="open in fullscreen"
          >
            <div className="plan-head">
              <span
                className={`plan-status plan-${p.kind === "unknown" ? "in-progress" : "approved"}`}
              >
                {p.kind}
              </span>
              <span className="plan-id">{p.slug.slice(0, 28)}</span>
              <span className="plan-date">
                {p.mtime_unix ? new Date(p.mtime_unix * 1000).toISOString().slice(0, 10) : ""}
              </span>
            </div>
            <div className="plan-title">{p.title ?? p.slug}</div>
            <div className="plan-meta">
              <CopyChip text={p.path} />
              <VSCodeBtn path={p.path} />
            </div>
          </div>
        ))}
      </div>
    </>
  );
}

// ─── 张飞 — shell scripts in ./scripts/ ───
function ScriptsBody({ worktree }: { worktree: string | null }) {
  const [data, setData] = useState<ScriptsPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<string>("__all");
  useEffect(() => {
    setData(null);
    setErr(null);
    api.scripts(worktree ?? undefined).then(setData).catch((e) => setErr(String(e)));
  }, [worktree]);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  if (data.error && data.scripts.length === 0) return <EmptyNote>{data.error}</EmptyNote>;

  const tabs = [
    { id: "__all", label: "All", count: data.scripts.length },
    ...data.categories.map((c) => ({ id: c.id, label: c.label, count: c.count })),
  ];
  const visible =
    tab === "__all" ? data.scripts : data.scripts.filter((s) => s.category === tab);

  return (
    <>
      <CharTabs tabs={tabs} active={tab} onChange={setTab} />
      <p style={{ fontSize: 11, color: "var(--ink-faint)", margin: "0 0 10px" }}>
        Root <CopyChip text={data.root} /> <VSCodeBtn path={data.root} />
      </p>
      <div className="run-list">
        {visible.length === 0 && <EmptyNote>no scripts in this category</EmptyNote>}
        {visible.map((s) => (
          <div
            key={s.path}
            className="run-row"
            style={{ borderLeft: "3px solid var(--accent)", paddingLeft: 10 }}
          >
            <div className="run-head" style={{ alignItems: "center", gap: 6 }}>
              <span aria-hidden style={{ fontSize: 14 }}>
                {s.executable ? "⚙️" : "📜"}
              </span>
              <button
                className="copy-pill"
                data-ref={s.path}
                data-action="open"
                style={{ display: "inline-flex", fontWeight: 600 }}
              >
                {s.name}
              </button>
              <span className="cat-badge" style={{
                fontSize: 10,
                textTransform: "uppercase",
                letterSpacing: 0.5,
                padding: "1px 6px",
                borderRadius: 4,
                background: "var(--paper-2)",
                color: "var(--ink-faint)",
              }}>
                {s.category}
              </span>
              <VSCodeBtn path={s.path} />
            </div>
            <div
              className="plan-meta"
              style={{ marginTop: 4, fontSize: 11, color: "var(--ink-faint)" }}
            >
              {s.line_count} lines · {s.size_bytes}B
              {s.executable ? " · executable" : " · not executable"}
              {s.modified && ` · ${s.modified}`}
            </div>
            {s.shebang && (
              <div
                className="mono"
                style={{
                  marginTop: 4,
                  fontSize: 11,
                  color: "var(--ink-faint)",
                  fontFamily: "JetBrains Mono, monospace",
                }}
              >
                {s.shebang}
              </div>
            )}
            {s.description && (
              <pre
                style={{
                  marginTop: 6,
                  padding: 8,
                  background: "var(--paper-2)",
                  border: "1px solid rgba(0,0,0,0.08)",
                  borderRadius: 6,
                  fontSize: 11.5,
                  lineHeight: 1.5,
                  fontFamily: "inherit",
                  whiteSpace: "pre-wrap",
                  margin: "6px 0 0",
                }}
              >
                {s.description}
              </pre>
            )}
            <details style={{ marginTop: 6 }}>
              <summary
                style={{
                  cursor: "pointer",
                  fontSize: 11,
                  color: "var(--ink-faint)",
                }}
              >
                Preview (first 80 lines)
              </summary>
              <pre
                style={{
                  marginTop: 6,
                  padding: 8,
                  background: "var(--paper-2)",
                  border: "1px solid rgba(0,0,0,0.08)",
                  borderRadius: 6,
                  fontSize: 11.5,
                  lineHeight: 1.45,
                  fontFamily: "JetBrains Mono, monospace",
                  maxHeight: 280,
                  overflow: "auto",
                  whiteSpace: "pre",
                }}
              >
                {s.excerpt}
              </pre>
            </details>
          </div>
        ))}
      </div>
    </>
  );
}

// ─── 赵云 — tests ───
function TestsBody() {
  const [data, setData] = useState<TestsPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    api.tests().then(setData).catch((e) => setErr(String(e)));
  }, []);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  if (data.error && data.crates.length === 0) return <EmptyNote>{data.error}</EmptyNote>;
  return (
    <>
      <SectionTitle>校场总览 · Tests by crate</SectionTitle>
      <div className="run-list">
        {data.crates.map((c) => (
          <div key={c.crate_name} className="run-row">
            <div className="run-head">
              <span className={`run-dot ${(c.last_run_failed ?? 0) === 0 ? "ok" : "bad"}`} />
              <span className="run-id">{c.crate_name}</span>
              <span className="run-date">
                {c.last_run_status ?? "—"} · {c.test_files.length} files
              </span>
            </div>
            <div className="run-stats">
              <span style={{ color: "#3F8C5C" }}>✓ {c.last_run_passed ?? "—"}</span>
              <span style={{ color: "#B83A3A" }}>✗ {c.last_run_failed ?? "—"}</span>
              <span>{c.coverage_pct != null ? `cov ${c.coverage_pct.toFixed(1)}%` : ""}</span>
            </div>
            {c.test_files.slice(0, 6).map((tf) => (
              <div key={tf.path} className="plan-meta" style={{ marginTop: 4 }}>
                <CopyChip text={tf.path} label={tf.name} />
                <VSCodeBtn path={tf.path} /> · {tf.line_count} lines
              </div>
            ))}
          </div>
        ))}
      </div>
    </>
  );
}

// ─── 马超 — github issues & PRs ───
function GhBody() {
  const [prs, setPrs] = useState<GhPayload | null>(null);
  const [issues, setIssues] = useState<GhPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<"prs" | "issues">("prs");
  useEffect(() => {
    Promise.all([api.prs(), api.issues()])
      .then(([p, i]) => {
        setPrs(p);
        setIssues(i);
      })
      .catch((e) => setErr(String(e)));
  }, []);
  if (err) return <div className="md-error">{err}</div>;
  if (!prs || !issues) return <EmptyNote>Loading…</EmptyNote>;

  const authError = prs.error?.toLowerCase().includes("auth") || prs.error?.toLowerCase().includes("not found");
  if (authError) {
    return (
      <div className="empty-note" style={{ padding: 20, textAlign: "center" }}>
        斥候未受令 · gh CLI not authed.
        <br />
        Run <code className="mono">gh auth login</code> in your terminal.
      </div>
    );
  }
  const prList = (Array.isArray(prs.items) ? prs.items : []) as Array<{
    number: number;
    title: string;
    url: string;
    state: string;
    isDraft?: boolean;
    author?: { login: string };
    updatedAt?: string;
  }>;
  const issueList = (Array.isArray(issues.items) ? issues.items : []) as Array<{
    number: number;
    title: string;
    url: string;
    author?: { login: string };
    labels?: { name: string }[];
    updatedAt?: string;
  }>;
  const tabs = [
    { id: "prs", label: "Pull Requests", count: prList.length },
    { id: "issues", label: "Issues", count: issueList.length },
  ];
  return (
    <>
      <CharTabs tabs={tabs} active={tab} onChange={(id) => setTab(id as "prs" | "issues")} />
      {tab === "prs" && (
        <>
          {prList.length === 0 && <EmptyNote>none</EmptyNote>}
          {prList.map((pr) => (
            <div key={pr.number} className="gh-row gh-row-full">
              <span className={`gh-pill gh-${pr.state.toLowerCase()}`}>#{pr.number} · {pr.state}{pr.isDraft ? " (draft)" : ""}</span>
              <span className="gh-text">{pr.title}</span>
              <span className="gh-meta">@{pr.author?.login ?? "?"} · {(pr.updatedAt ?? "").slice(0, 10)}</span>
            </div>
          ))}
        </>
      )}
      {tab === "issues" && (
        <>
          {issueList.length === 0 && <EmptyNote>none</EmptyNote>}
          {issueList.map((iss) => (
            <div key={iss.number} className="gh-row gh-row-full">
              <span className="gh-pill gh-issue">#{iss.number}</span>
              <span className="gh-text">{iss.title}</span>
              <span className="gh-meta">{(iss.labels ?? []).map((l) => l.name).join(" · ")}</span>
            </div>
          ))}
        </>
      )}
    </>
  );
}

// ─── 黄忠 — cloud / IAM / users ───
function CloudBody() {
  const [data, setData] = useState<CloudSettingsPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<"settings" | "iam" | "users">("settings");
  useEffect(() => {
    api.cloudSettings().then(setData).catch((e) => setErr(String(e)));
  }, []);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;
  const tabs = [
    { id: "settings", label: "Configs", count: data.settings.length },
    { id: "iam", label: "IAM Roles", count: data.iam_roles.length },
    { id: "users", label: "Users", count: data.users.length },
  ];
  return (
    <>
      <CharTabs
        tabs={tabs}
        active={tab}
        onChange={(id) => setTab(id as "settings" | "iam" | "users")}
      />
      {tab === "settings" && (
        <>
          {data.settings.map((s) => (
            <div key={s.path} className="file-row">
              <div className="file-row-main">
                <CopyChip text={s.path} />
                {s.exists && <VSCodeBtn path={s.path} />}
                <span className="file-row-loc">{s.exists ? "ok" : "missing"}</span>
              </div>
              <div className="file-row-desc">
                <strong>{s.source}</strong> · {s.description}
              </div>
            </div>
          ))}
        </>
      )}
      {tab === "iam" && (
        <>
          {data.iam_roles.length === 0 && <EmptyNote>none configured</EmptyNote>}
          {data.iam_roles.map((role) => (
            <div key={role} className="dep-chip">
              <span className="mono">{role}</span>
            </div>
          ))}
        </>
      )}
      {tab === "users" && (
        <>
          {data.users.length === 0 && <EmptyNote>none configured</EmptyNote>}
          {data.users.map((u) => (
            <div key={u.name} className="dep-chip">
              {u.name} <span className="mono">· {u.source}</span>
            </div>
          ))}
        </>
      )}
    </>
  );
}

// ─── 魏延 — env / shell / CLAUDE.md / ssh / project .claude ───
function EnvBody() {
  const [data, setData] = useState<EnvSettingsPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<string>("shell");
  useEffect(() => {
    api.envSettings().then(setData).catch((e) => setErr(String(e)));
  }, []);
  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <EmptyNote>Loading…</EmptyNote>;

  const isEnvFile = (p: string) => {
    const name = p.split("/").pop() ?? "";
    const lower = name.toLowerCase();
    return (
      lower === ".env" ||
      lower.startsWith(".env.") ||
      lower.endsWith(".env") ||
      lower.includes(".env.")
    );
  };
  const groups = {
    shell: data.files.filter((f) => /\.(zshenv|zshrc|bashrc|profile)$/i.test(f.path)),
    env: data.files.filter((f) => isEnvFile(f.path)),
    claude: data.files.filter(
      (f) =>
        !isEnvFile(f.path) &&
        (f.path.includes("/.claude/") || /CLAUDE\.md|AGENTS\.md/i.test(f.path)),
    ),
    ssh: data.files.filter((f) => f.path.includes("/.ssh/")),
    aws: data.files.filter((f) => f.path.includes("/.aws/")),
  };
  const other = data.files.filter(
    (f) =>
      !groups.shell.includes(f) &&
      !groups.env.includes(f) &&
      !groups.claude.includes(f) &&
      !groups.ssh.includes(f) &&
      !groups.aws.includes(f),
  );
  if (other.length) groups.claude = [...groups.claude, ...other];

  const tabs = [
    { id: "shell", label: "Shell", count: groups.shell.length },
    { id: "env", label: "Env files", count: groups.env.length },
    { id: "claude", label: ".claude / CLAUDE.md", count: groups.claude.length },
    { id: "ssh", label: "SSH", count: groups.ssh.length },
    { id: "aws", label: "AWS", count: groups.aws.length },
    { id: "vars", label: "Env vars", count: data.env_vars.length },
  ];

  const renderFiles = (files: typeof data.files) => (
    <>
      {files.length === 0 && <EmptyNote>none</EmptyNote>}
      {files.map((f) => (
        <div key={f.path} className="file-row" style={{ marginBottom: 8 }}>
          <div className="file-row-main">
            <button
              className="copy-pill"
              data-ref={f.path}
              data-action={f.path.toLowerCase().endsWith(".md") ? "open" : "copy"}
            >
              {f.path}
            </button>
            {f.exists && <VSCodeBtn path={f.path} />}
            <span className="file-row-loc">
              {f.exists ? `${f.line_count} lines · ${f.size_bytes}B` : "missing"}
            </span>
          </div>
          {f.exists && f.excerpt && (
            <pre
              style={{
                marginTop: 8,
                padding: 10,
                background: "var(--paper-2)",
                border: "1px solid rgba(0,0,0,0.08)",
                borderRadius: 6,
                fontSize: 11.5,
                lineHeight: 1.5,
                fontFamily: "JetBrains Mono, monospace",
                maxHeight: 220,
                overflow: "auto",
              }}
            >
              {f.excerpt}
            </pre>
          )}
        </div>
      ))}
    </>
  );

  return (
    <>
      <CharTabs tabs={tabs} active={tab} onChange={setTab} />
      {tab === "shell" && renderFiles(groups.shell)}
      {tab === "env" && renderFiles(groups.env)}
      {tab === "claude" && renderFiles(groups.claude)}
      {tab === "ssh" && renderFiles(groups.ssh)}
      {tab === "aws" && renderFiles(groups.aws)}
      {tab === "vars" && (
        <div className="kv-list">
          {data.env_vars.length === 0 && <EmptyNote>none</EmptyNote>}
          {data.env_vars.map((v) => (
            <div key={v.key} className="kv-row">
              <span className="kv-key">{v.key}</span>
              <span className="kv-val">{v.value}</span>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
