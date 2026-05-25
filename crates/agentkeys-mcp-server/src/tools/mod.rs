//! Tool registry — the 7 active + 3 schema-only tools listed in issue #107.
//!
//! Tool naming follows the issue verbatim: dotted `agentkeys.<area>.<verb>`.
//! Each handler returns a `Value` that gets wrapped in the MCP `tools/call`
//! envelope by `server::dispatch_tool_call`.

pub mod audit;
pub mod cap;
pub mod identity;
pub mod memory;
pub mod permission;
pub mod stubs;

use crate::mcp::ToolDescriptor;
use serde_json::json;

pub const TOOL_IDENTITY_WHOAMI: &str = "agentkeys.identity.whoami";
pub const TOOL_MEMORY_GET: &str = "agentkeys.memory.get";
pub const TOOL_MEMORY_PUT: &str = "agentkeys.memory.put";
pub const TOOL_PERMISSION_CHECK: &str = "agentkeys.permission.check";
pub const TOOL_CAP_MINT: &str = "agentkeys.cap.mint";
pub const TOOL_CAP_REVOKE: &str = "agentkeys.cap.revoke";
pub const TOOL_AUDIT_APPEND: &str = "agentkeys.audit.append";
pub const TOOL_DELEGATION_GRANT: &str = "agentkeys.delegation.grant";
pub const TOOL_DELEGATION_REVOKE: &str = "agentkeys.delegation.revoke";
pub const TOOL_APPROVAL_REQUEST: &str = "agentkeys.approval.request";

pub fn all_descriptors() -> Vec<ToolDescriptor> {
    vec![
        ToolDescriptor {
            name: TOOL_IDENTITY_WHOAMI.into(),
            description: "Return identity facts (omni, display_name, vendor, scopes) for the calling actor.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string", "description": "Actor omni (32-byte hex)."}
                },
                "required": ["actor"]
            }),
        },
        ToolDescriptor {
            name: TOOL_MEMORY_GET.into(),
            description: "Cap-token-verified read of the calling actor's memory, filtered by namespace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "namespace": {"type": "string", "description": "Memory namespace, e.g. `travel`, `family`, `profile`."},
                    "operator_omni": {"type": "string"},
                    "service": {"type": "string", "default": "memory"},
                    "device_key_hash": {"type": "string"},
                    "ttl_seconds": {"type": "integer", "default": 300}
                },
                "required": ["actor", "namespace", "operator_omni", "device_key_hash"]
            }),
        },
        ToolDescriptor {
            name: TOOL_MEMORY_PUT.into(),
            description: "Cap-token-verified write of memory content under a given namespace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "namespace": {"type": "string"},
                    "content": {"type": "string", "description": "Raw plaintext to store; base64 encoded by the server."},
                    "operator_omni": {"type": "string"},
                    "service": {"type": "string", "default": "memory"},
                    "device_key_hash": {"type": "string"},
                    "ttl_seconds": {"type": "integer", "default": 300}
                },
                "required": ["actor", "namespace", "content", "operator_omni", "device_key_hash"]
            }),
        },
        ToolDescriptor {
            name: TOOL_PERMISSION_CHECK.into(),
            description: "Deterministic policy engine — returns accept|deny|ask_parent for (actor, scope, params).".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "scope": {"type": "string"},
                    "params": {"type": "object", "additionalProperties": true}
                },
                "required": ["actor", "scope"]
            }),
        },
        ToolDescriptor {
            name: TOOL_CAP_MINT.into(),
            description: "Mint a bounded-TTL capability token for one of cred_store|cred_fetch|memory_put|memory_get.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "op": {
                        "type": "string",
                        "enum": ["cred_store", "cred_fetch", "memory_put", "memory_get"]
                    },
                    "params": {
                        "type": "object",
                        "properties": {
                            "operator_omni": {"type": "string"},
                            "service": {"type": "string"},
                            "device_key_hash": {"type": "string"}
                        },
                        "required": ["operator_omni", "service", "device_key_hash"]
                    },
                    "ttl": {"type": "integer", "default": 300}
                },
                "required": ["actor", "op", "params"]
            }),
        },
        ToolDescriptor {
            name: TOOL_CAP_REVOKE.into(),
            description: "Revoke a cap by id. M1 records locally; broker endpoint scheduled for M4.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "cap_id": {"type": "string"}
                },
                "required": ["cap_id"]
            }),
        },
        ToolDescriptor {
            name: TOOL_AUDIT_APPEND.into(),
            description: "Append an audit envelope. Real-time off-chain feed; 2-min batched on-chain anchor (issue #109).".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "event": {
                        "type": "object",
                        "properties": {
                            "operator_omni": {"type": "string"},
                            "op_kind": {"type": "integer"},
                            "op_body": {"type": "object", "additionalProperties": true},
                            "result": {"type": "integer", "enum": [0, 1, 2]},
                            "intent_text": {"type": "string"}
                        },
                        "required": ["operator_omni", "op_kind", "result"]
                    }
                },
                "required": ["actor", "event"]
            }),
        },
        ToolDescriptor {
            name: TOOL_DELEGATION_GRANT.into(),
            description: "[M4] Grant a scoped delegation from one actor to another. Returns not_implemented_in_v1.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "delegator": {"type": "string"},
                    "delegate": {"type": "string"},
                    "scope": {"type": "string"},
                    "ttl": {"type": "integer"}
                },
                "required": ["delegator", "delegate", "scope"]
            }),
        },
        ToolDescriptor {
            name: TOOL_DELEGATION_REVOKE.into(),
            description: "[M4] Revoke a delegation. Returns not_implemented_in_v1.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "delegation_id": {"type": "string"}
                },
                "required": ["delegation_id"]
            }),
        },
        ToolDescriptor {
            name: TOOL_APPROVAL_REQUEST.into(),
            description: "[M4] Request parent approval for an action. Returns not_implemented_in_v1.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string"},
                    "scope": {"type": "string"},
                    "params": {"type": "object", "additionalProperties": true}
                },
                "required": ["actor", "scope"]
            }),
        },
    ]
}
