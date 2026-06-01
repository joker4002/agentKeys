import type {
  BattleDetail,
  CratesPayload,
  CloudSettingsPayload,
  ClaudePlansPayload,
  DocsPayload,
  EnvSettingsPayload,
  GhPayload,
  GraphPayload,
  JjPayload,
  MarkdownPayload,
  WorktreesPayload,
  PlanDetail,
  PlanKind,
  PlansPayload,
  ScriptsPayload,
  TestsPayload,
} from "./types";

async function getJson<T>(path: string): Promise<T> {
  const r = await fetch(path);
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  return (await r.json()) as T;
}

export const api = {
  crates: () => getJson<CratesPayload>("/api/crates"),
  graph: () => getJson<GraphPayload>("/api/graph"),

  plans: (kind?: PlanKind) =>
    getJson<PlansPayload>(kind ? `/api/plans?kind=${kind}` : "/api/plans"),
  planDetail: (slug: string) =>
    getJson<PlanDetail>(`/api/plans/${encodeURIComponent(slug)}`),

  scripts: (repo?: string) =>
    getJson<ScriptsPayload>(repo ? `/api/scripts?repo=${encodeURIComponent(repo)}` : "/api/scripts"),

  tests: () => getJson<TestsPayload>("/api/tests"),
  prs: () => getJson<GhPayload>("/api/gh/prs"),
  issues: () => getJson<GhPayload>("/api/gh/issues"),

  // New endpoints (added below in viz/server)
  docs: (repo?: string) =>
    getJson<DocsPayload>(repo ? `/api/docs?repo=${encodeURIComponent(repo)}` : "/api/docs"),
  worktrees: () => getJson<WorktreesPayload>("/api/worktrees"),
  claudePlans: () => getJson<ClaudePlansPayload>("/api/claude-plans"),
  envSettings: () => getJson<EnvSettingsPayload>("/api/env-settings"),
  cloudSettings: () => getJson<CloudSettingsPayload>("/api/cloud-settings"),
  markdown: (path: string) =>
    getJson<MarkdownPayload>(`/api/markdown?path=${encodeURIComponent(path)}`),

  battleDetail: (pid: number) => getJson<BattleDetail>(`/api/battles/${pid}`),

  jj: () => getJson<JjPayload>("/api/jj"),
};

export function battlesStream(onEvent: (raw: unknown) => void): EventSource {
  const es = new EventSource("/api/battles");
  es.onmessage = (e) => {
    try {
      onEvent(JSON.parse(e.data));
    } catch {
      // ignore malformed events
    }
  };
  return es;
}
