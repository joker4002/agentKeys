# Plan

Agent-authored implementation plans (Claude, codex, ralph) drafted **before** the code lands. Each file describes the intended change, the stages, and the verification.

## Promotion / archival

- When the plan's code ships and you want to keep the contract durable (interfaces, protocol shapes, terminology), **promote** the file to `../spec/` and update [`../arch.md`](../arch.md) to link to it.
- Otherwise, **archive** to `../archived/`. Plans for shipped work do not accumulate here.

## Style

Plain markdown. No YAML frontmatter. Link to repo files with `../../<path>` and to other docs with `../<file>.md` or `../spec/<file>.md`.

See the `agentkeys-docs` skill for the full layout policy.
