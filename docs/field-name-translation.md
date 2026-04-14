# Field-Name Translation — design note

**Status:** living document. Update when a new surface is added, the backend schema changes, or Apple changes `security(1)`'s output.

**Scope:** explains why `docs/manual-test-stage4.md` uses a client-side sed pretty-printer for macOS Keychain output, and the general principle that applies to every future AgentKeys surface.

## 1. The immediate problem

`security(1)` surfaces Apple's 4-char FourCharCode attribute names (`svce`, `acct`, `cdat`, `mdat`, etc.) — 32-bit integer constants from `<Security/SecKeychainItem.h>` that happen to be valid ASCII when viewed as 4 bytes. This is Apple's OSType convention, inherited from Classic Mac OS and frozen binary ABI. The modern `SecItem*` CFDictionary API layers symbolic `kSecAttr*` CFString constants on top, but the wire bytes underneath are still `'svce'`, and `security(1)` prints those raw.

Manual-test readers need to eyeball `ak-keychain-meta` output to confirm a test passed. Cryptic 4-char names make that slow.

## 2. The general principle

> **Compact wire formats are for machines; human-readable labels are for humans; translate at the layer closest to the human.**

Three corollaries:

1. **Don't invent cryptic field names at layers you control.** The backend Rust types in `crates/agentkeys-types/src/lib.rs` (`AuditEvent`, `Session`, `AuthRequest`, …) use self-describing fields (`owner`, `agent`, `service`, `action`, `result`, `timestamp`). Don't regress to compact names for "efficiency" when the data is JSON over HTTPS anyway.
2. **Translation belongs at the client, not the server.** The backend emits neutral data; each client chooses how to render. A future mobile UI, web dashboard, and log viewer each build their own formatter — they do NOT ask the backend to add display strings to its responses.
3. **Always keep an escape hatch to the raw form.** `ak-keychain-meta-raw`, `?format=raw` query params, verbose mode flags. If the pretty-printer is ever wrong, the user must be able to see the unvarnished source-of-truth in one command.

## 3. How this maps to AgentKeys today

The 8-stage plan (0–7) has no mobile or web UI. Every human-visible surface in stages 0–7 is either:
- terminal output from `agentkeys-cli` (Rust — already uses self-describing field names), or
- prose in `docs/` / `README.md` / `wiki/` (Markdown).

So the ONE place where we touch Apple's 4-char codes is `security(1)` output inside the manual test scripts. That's where the sed translator lives — layer 1, closest to the human.

Future surfaces (NOT in current plan, flagged for when they're designed):

| Surface | Translation responsibility | Where |
|---|---|---|
| Mobile master app (speculative) | App builds its own formatter from backend JSON. No backend-side display strings. | App code. |
| Web dashboard (speculative) | Web client builds its own formatter. | Web client code. |
| Log viewer / TUI (speculative) | TUI builds its own formatter. | TUI code. |

## 4. Translation tables

### Layer 1 — Apple Keychain 4-char codes (used in `ak-keychain-meta`)

Source: `<Security/SecKeychainItem.h>` (macOS SDK).

| 4-char | Apple constant | Human label |
|---|---|---|
| `svce` | `kSecServiceItemAttr` | `service` |
| `acct` | `kSecAccountItemAttr` | `account` |
| `cdat` | `kSecCreationDateItemAttr` | `created` |
| `mdat` | `kSecModDateItemAttr` | `modified` |
| `crtr` | `kSecCreatorItemAttr` | `creator` |
| `type` | `kSecTypeItemAttr` | `type` |
| `desc` | `kSecDescriptionItemAttr` | `description` |
| `icmt` | `kSecCommentItemAttr` | `comment` |
| `gena` | `kSecGenericItemAttr` | `generic_data` |
| `invi` | `kSecInvisibleItemAttr` | `invisible` |
| `nega` | `kSecNegativeItemAttr` | `negative_flag` |
| `prot` | `kSecProtocolItemAttr` | `protocol` |
| `scrp` | `kSecScriptCodeItemAttr` | `script_code` |
| `cusi` | `kSecCustomIconItemAttr` | `custom_icon` |
| `0x00000007` | `kSecLabelItemAttr` | `label` |
| `0x00000008` | `kSecAliasItemAttr` | `alias` |

### Layer 2 — Backend Rust types (already self-describing)

`crates/agentkeys-types/src/lib.rs` already uses plain English field names:

```rust
pub struct AuditEvent {
    pub owner: WalletAddress,
    pub agent: WalletAddress,
    pub service: ServiceName,
    pub action: String,       // "store" | "read" | "revoke" | ...
    pub result: String,       // "ok" | "denied" | "not_found" | ...
    pub timestamp: u64,
}
```

No translation needed at the backend. Clients render these directly.

## 5. When to update this doc

- A new surface is added (e.g. web dashboard, mobile app, TUI log viewer) — add a row to §3 with its translation responsibility.
- The backend schema changes — if any field name becomes a compact code, document it and translate at the client.
- Apple changes `security(1)`'s output format — update the sed patterns in `docs/manual-test-stage4.md` and this doc's Layer-1 table.

## Cross-references

- `docs/manual-test-stage4.md` — `ak-keychain-meta` / `ak-keychain-meta-raw` helpers, Test 0.
- `crates/agentkeys-types/src/lib.rs` — backend data types (Layer-2 example).
- `docs/spec/plans/development-stages.md` — the 8-stage plan (confirms no web/mobile surface in stages 0–7).
- Apple docs: `<Security/SecKeychainItem.h>` (macOS SDK headers, source of truth for Layer-1 codes).

## Related

- GitHub issue [#1](https://github.com/litentry/agentKeys/issues/1) — originating issue.
