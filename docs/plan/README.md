# Plan

Agent-authored implementation plans (Claude, codex, ralph) drafted **before** the code lands. Each file describes the intended change, the stages, and the verification.

## Promotion / archival

- When the plan's code ships and you want to keep the contract durable (interfaces, protocol shapes, terminology), **promote** the file to `../spec/` and update [`../arch.md`](../arch.md) to link to it.
- Otherwise, **archive** to `../archived/`. Plans for shipped work do not accumulate here.

## Style

Plain markdown. No YAML frontmatter. Link to repo files with `../../<path>` and to other docs with `../<file>.md` or `../spec/<file>.md`.

See the `agentkeys-docs` skill for the full layout policy.

## Active plans

- [`agentkeys-memory-design.md`](agentkeys-memory-design.md) — memory worker design (single file).
- [`web-flow/`](web-flow/) — parent-control web UI operator user flow. Multi-file. Binds harness v2-stage {1,2,3} flows to UI screens with real inputs (no mock data). Start at [`web-flow/README.md`](web-flow/README.md).
