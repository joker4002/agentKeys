# Changelog

All notable changes to AgentKeys are tracked here.

## 2026-06-01

### Added

- Full agent bootstrap ceremony for HDKD-derived agents, including broker link-code endpoints, daemon-side redeem, pending bindings, and the bind/grant split. See PR #149.
- Hooks-first Hermes wiring for AgentKeys, including `agentkeys wire`, `agentkeys hook check`, `agentkeys hook audit`, `agentkeys hook memory-inject`, and the operator runbook. See PR #141.

### Changed

- Locked the memory architecture direction around the gated-backend model: AgentKeys owns the encrypted, per-actor store and deterministic gate, while ranking and extraction engines stay pluggable. See PR #146.
- Cleaned and indexed the architecture docs around memory, universal gate behavior, and design-record links. See PR #146.

### Notes

- The next active slices are namespace-bound memory caps, device lifecycle handling, hosted-LLM MCP deployment, and the brand asset PR.
