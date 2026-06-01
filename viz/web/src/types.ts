// Shared types — frontend mirror of viz/server/src/api/*.rs JSON payloads,
// plus the Three Kingdoms reference data shipped under viz/threeKingdoms/.

// ─── Three Kingdoms reference data ───
export interface Region {
  id: string;
  name: string;
  pinyin: string;
  english: string;
  subtitle: string;
  color: string;
  colorSoft: string;
  ink: string;
  suggestedFor: string[];
}

export interface Town {
  name: string;
  pinyin: string;
  kind: "capital" | "city" | "commandery" | "kingdom" | "pass" | "fortress";
}

export interface Character {
  id: string;
  name: string;
  pinyin: string;
  title: string;
  role: string;
  tagline: string;
  color: string;
  ink: string;
  domain: string;
  endpoint: string;
  trigger: string;
}

// ─── Map data (composed from /api/crates + /api/graph + threeKingdoms) ───
export interface ModuleTile {
  id: string;
  name: string;       // module name (e.g. "kernel", "router")
  cn: string;         // Chinese town name (e.g. "成都")
  pinyin: string;
  territory: string;  // region id
  q: number;
  r: number;
  path: string;
  files: number;
  loc: number;
  desc: string;
  isCapital: boolean;
}

export interface Edge {
  from: string;
  to: string;
}

export interface MapTile {
  q: number;
  r: number;
  regionId: string | null; // null = wilderness/unused (rendered grey)
  moduleId: string | null; // null = empty land within a region
  townName: string | null;   // Chinese town name (e.g. "成都")
  townPinyin: string | null;
  townKind: string | null;   // "capital" | "city" | "commandery" | etc.
  isCapital: boolean;
}

export interface MapData {
  regions: Region[];
  modules: ModuleTile[];
  tiles: MapTile[];
  edges: Edge[];
  characters: Character[];
  activeRegionIds: string[]; // regions backed by a real crate; others render greyed
}

// ─── Backend payloads ───
export interface CrateInfo {
  name: string;
  version: string;
  manifest_path: string;
  deps: string[];
}

export interface CratesPayload {
  crates: CrateInfo[];
}

export interface GraphNode {
  id: string;
  layer: number;
  kind: string;
}

export interface GraphPayload {
  nodes: GraphNode[];
  edges: Edge[];
}

export type PlanKind = "ceo" | "eng" | "unknown";

export interface PlanSummary {
  slug: string;
  title: string | null;
  kind: PlanKind;
  mtime_unix: number;
  path: string;
}

export interface PlansPayload {
  plans: PlanSummary[];
  error: string | null;
}

export interface PlanDetail {
  slug: string;
  title: string | null;
  kind: PlanKind;
  raw_markdown: string;
  raw_path: string;
}

export interface ScriptInfo {
  name: string;
  path: string;
  category: string;
  size_bytes: number;
  line_count: number;
  executable: boolean;
  shebang?: string;
  description?: string;
  excerpt: string;
  modified?: string;
}

export interface ScriptCategory {
  id: string;
  label: string;
  count: number;
}

export interface ScriptsPayload {
  root: string;
  scripts: ScriptInfo[];
  categories: ScriptCategory[];
  error: string | null;
}

export interface CrateTests {
  crate_name: string;
  test_files: { name: string; path: string; line_count: number }[];
  last_run_status: string | null;
  last_run_passed: number | null;
  last_run_failed: number | null;
  coverage_pct: number | null;
}

export interface TestsPayload {
  crates: CrateTests[];
  cache_dir: string;
  error: string | null;
}

export interface GhPayload {
  items: unknown;
  error: string | null;
}

// ─── New endpoints (法正 / 庞统 / 黄忠 / 魏延) ───
export interface DocsNode {
  name: string;
  path: string;
  is_dir: boolean;
  children?: DocsNode[];
  line_count?: number;
  /** True for a pinned single-source-of-truth doc (arch.md = technical,
   * agent-iam-strategy.md = product). Pinned to the top of the panel. */
  is_index?: boolean;
  /** Caption shown under a pinned SSOT doc; set only when is_index is true. */
  index_caption?: string;
  /** For top-level docs/ subfolders, the audience caption per arch.md "Docs layout (lean)". */
  audience?: string;
  /** Direct-entry count for a collapsed, un-expanded dir (e.g. archived/). */
  entry_count?: number;
}

export interface DocsPayload {
  root: string;
  tree: DocsNode[];
  /** Absolute path to docs/arch.md if present. */
  index_path?: string;
  error: string | null;
}

export interface ClaudePlanSection {
  label: string;
  dir: string;
  exists: boolean;
  plans: PlanSummary[];
}

export interface ClaudePlansPayload {
  dir: string;
  plans: PlanSummary[];
  sections: ClaudePlanSection[];
  error: string | null;
}

export interface EnvFile {
  path: string;
  exists: boolean;
  size_bytes: number;
  line_count: number;
  excerpt: string;
}

export interface EnvSettingsPayload {
  files: EnvFile[];
  env_vars: { key: string; value: string }[];
  error: string | null;
}

export interface CloudSetting {
  source: string;
  path: string;
  exists: boolean;
  description: string;
}

export interface CloudSettingsPayload {
  settings: CloudSetting[];
  iam_roles: string[];
  users: { name: string; source: string }[];
  error: string | null;
}

export interface MarkdownPayload {
  path: string;
  raw_markdown: string;
  error: string | null;
}

// ─── Battles SSE ───
export type BattleKind = "cargotest" | "claude" | "codex" | "ralph" | "provisioner" | "other";

export interface Battle {
  pid: number;
  kind: BattleKind;
  label: string;
  crate_name: string | null;
}

export type BattleEvent =
  | { type: "snapshot"; battles: Battle[] }
  | { type: "diff"; added: Battle[]; removed: Battle[]; current: Battle[] };

export interface BattleDetail {
  pid: number;
  ppid: number | null;
  user: string | null;
  started: string | null;
  command: string | null;
  cwd: string | null;
  exists: boolean;
  error: string | null;
}

// ─── Selection ───
export type Selection =
  | { kind: "module"; id: string }
  | { kind: "character"; id: string }
  | null;

// ─── Markdown tabs (chrome-style) ───
export interface MarkdownTab {
  path: string;
  title: string;
  body: string | null; // null while loading
  error: string | null;
}

export interface JjEntry {
  change_id: string;
  description: string;
  bookmarks: string[];
  is_working_copy: boolean;
}

export interface JjBookmark {
  name: string;
  change_id: string;
  description: string;
  remote: string | null;
}

export interface JjPayload {
  log: JjEntry[];
  bookmarks: JjBookmark[];
  repo: string;
  error: string | null;
}

export interface Worktree {
  path: string;
  branch: string | null;
  head: string | null;
  is_main: boolean;
  is_detached: boolean;
  label: string;
  contained_in: string[];
}

export interface WorktreesPayload {
  worktrees: Worktree[];
  current: string;
  error: string | null;
}
