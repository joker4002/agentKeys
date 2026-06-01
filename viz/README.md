# viz — agentKey 蜀汉地图

Boardgame-style codebase atlas for agentKeys. Drop-in replacement for the earlier pixel-art prototype — parchment palette, hex tiles, drag-pannable map. Read-only orientation tool: the user keeps writing code in Claude Desktop / Codex Desktop.

## Layout

```
viz/
├── threeKingdoms/    Reference data — regions, towns, characters from
│                     Total War: Three Kingdoms. Read by both the sync
│                     skill (writes layout JSON) and the frontend (loads
│                     palette/names).
├── server/           Standalone Rust crate (axum). NOT in the agentkeys
│                     workspace — has its own [workspace] table.
└── web/              TypeScript SPA (Vite + React + markdown-it). Hex
                      map, council bar, side panels, in-app markdown
                      rendering. Builds to web/dist/.
```

## Three Kingdoms metaphor

| codebase concept | metaphor | reference data |
|---|---|---|
| `crates/<name>/` | **region** (州) | [`threeKingdoms/regions.json`](threeKingdoms/regions.json) |
| core module inside a crate | **town** (县/关) | [`threeKingdoms/towns.json`](threeKingdoms/towns.json) |
| user's lieutenants | **shu council** (蜀国群英) | [`threeKingdoms/characters.json`](threeKingdoms/characters.json) |

The 9 council characters are NOT bound to tiles — they ride the top bar and report on cross-cutting concerns:

- **诸葛亮** — CEO plans (`/plan-ceo-review`)
- **法正** — docs entry (`docs/` tree)
- **庞统** — `~/.claude/plans/*.md`
- **关羽** — eng plans (`/plan-eng-review`)
- **张飞** — shell scripts under `./scripts/`
- **赵云** — tests + coverage
- **马超** — github issues + PRs
- **黄忠** — cloud · roles · users
- **魏延** — env · CLAUDE.md · shell config

Click any rendered `path/to/file.md:42` reference to render that file in-app via the `MarkdownPanel`.

## Run

```sh
# One-time
cd viz/web && npm install

# Production
cd viz/web    && npm run build           # outputs viz/web/dist/
cd viz/server && cargo run --release     # serves dist/ + JSON API on :8092
# open http://127.0.0.1:8092

# Dev (two terminals, hot-reload)
cd viz/server && AGENTKEYS_VIZ_DEV=1 cargo run    # backend on :8092
cd viz/web    && npm run dev                       # Vite on :5173 (proxies /api → 8092)
```

## Endpoints

| route | character | source |
|---|---|---|
| `/api/crates` · `/api/graph` | (map) | `cargo metadata` |
| `/api/plans?kind=ceo` | 诸葛亮 | `~/.claude/plans/*.md` |
| `/api/plans?kind=eng` | 关羽 | `~/.claude/plans/*.md` |
| `/api/claude-plans` | 庞统 | full `~/.claude/plans/` directory |
| `/api/docs` | 诸葛亮 | recursive walk of `docs/` — pins `arch.md` (technical SSOT) + `agent-iam-strategy.md` (product SSOT) on top; root files are the default view, each subfolder (`spec/` `plan/` `research/` `wiki/` `archived/`) is a tab with its audience caption; `archived/` is left collapsed (count only) |
| `/api/scripts` | 张飞 | `<repo>/scripts/` — shell scripts grouped by category (heima-*, setup-*, stage*-*, provision-*) with shebang + extracted description |
| `/api/tests` | 赵云 | per-crate `tests/` + cached `cargo test` |
| `/api/gh/{prs,issues}` | 马超 | `gh` CLI |
| `/api/cloud-settings` | 黄忠 | AWS/GCP/kubectl/Anthropic config files |
| `/api/env-settings` | 魏延 | `~/.zshenv`, `~/.zshrc`, `CLAUDE.md`, env vars (redacted) |
| `/api/markdown?path=…` | (any) | reads any `.md` under repo or `~/.claude/` |
| `/api/battles` (SSE) | dock | `ps -A` polling, 2s interval |

## Sync skill

Run [`/agentkeys-viz-sync`](https://github.com/) (installed at `~/.claude/skills/agentkeys-viz-sync/`) to regenerate `viz/web/public/map-layout.json` whenever the codebase changes — new crates, new modules, new plans, new scripts. Reads region/town names from `threeKingdoms/`.
