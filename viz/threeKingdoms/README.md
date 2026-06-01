# Three Kingdoms naming reference

Reference data for the agentKey viz dashboard. Inspired by **Total War: Three Kingdoms** province + commandery naming.

## Mapping rule

| codebase | metaphor | data file |
|---|---|---|
| `crates/<name>/` | **region** (州/郡) — territory color, capital, ink | [`regions.json`](regions.json) |
| core module inside a crate (top-level `src/<module>.rs` or `src/<module>/`) | **town** (县/关) — hex tile on the map | [`towns.json`](towns.json) |
| user's lieutenants (cross-cutting) | **shu kingdom council** (蜀汉群英) | [`characters.json`](characters.json) |

The viz sync skill consumes these files to produce stable Three-Kingdoms-style placenames whenever the codebase grows. Every region carries its own ink/paper palette so the boardgame map stays legible at a glance.

## Regions

The 13 historical Han provinces (州) plus two strategic prefectures (汉中, 南中). Pick one per crate based on its role:

- **司隶 (Sili)** — imperial center; the crate everyone depends on (reserved for `agentkeys-types`).
- **益州 (Yi)** — Sichuan basin; long-lived stronghold (good for `agentkeys-daemon`).
- **荆州 (Jing)** — north–south corridor; gateway crate (`agentkeys-cli`).
- **汉中 (Hanzhong)** — mountain pass; bridging/broker concerns (`agentkeys-broker-server`).
- **南中 (Nanzhong)** — southern frontier; mock/disposable systems (`agentkeys-mock-server`).
- **雍州 (Yong)** — protocol corridor (`agentkeys-mcp`).
- **扬州 (Yang)** — outward commerce (`agentkeys-provisioner`).
- **兖州 (Yan)** — central operations (`agentkeys-core`).
- Spillover: 豫州, 冀州, 青州, 徐州, 凉州, 并州, 幽州, 交州 — extra regions if the workspace grows.

## Towns

Each region in [`towns.json`](towns.json) lists historically-attested towns/passes. The first entry is the **regional capital** (state capital, marked ▼ on the map). Prefer to assign:

- The crate's foundational module (`lib.rs`, `kernel`, `state.rs`) → capital town.
- Other key modules → secondary towns (counties, passes).
