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
    // NOTE on schemas: `actor`, `operator_omni`, `device_key_hash` are
    // ambient identity fields the LLM has no way to fabricate. They're
    // resolved server-side from MCP_DEFAULT_* env vars (auto-set to the
    // demo fixture in --backend=in-memory mode). LLM-callable params
    // (`namespace`, `content`, `scope`, etc.) stay in `required`.
    vec![
        ToolDescriptor {
            name: TOOL_IDENTITY_WHOAMI.into(),
            description: "Return basic identity info for the current user — their account id, display name, and which permissions they have. Call this when the user asks 'who am I', 'what's my account', or you need to know who you're talking to before another action.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "actor": {"type": "string", "description": "Optional. The server uses its configured actor by default."}
                }
            }),
        },
        ToolDescriptor {
            name: TOOL_MEMORY_GET.into(),
            description: "Recall what the user has previously saved or told you to remember about a topic. Use this when the user references their past or current state: 'where am I going', 'where did I go', 'what do I like', 'who is my [family member]', 'do I have any allergies', 'remember when I…'. Returns the saved note as a string.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Topic. Use 'travel' for trips/destinations/plans, 'family' for relatives/birthdays/relationships, 'profile' for preferences/allergies/dietary needs.",
                        "enum": ["travel", "family", "profile"]
                    }
                },
                "required": ["namespace"]
            }),
        },
        ToolDescriptor {
            name: TOOL_MEMORY_PUT.into(),
            description: "Save something the user wants you to remember. Use when the user says 'remember that…', 'note that…', 'save this'. Group memories by topic via the namespace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Topic. Use 'travel' for trips, 'family' for relatives, 'profile' for preferences.",
                        "enum": ["travel", "family", "profile"]
                    },
                    "content": {"type": "string", "description": "What to remember, in natural language."}
                },
                "required": ["namespace", "content"]
            }),
        },
        ToolDescriptor {
            name: TOOL_PERMISSION_CHECK.into(),
            description: "Check whether the user is allowed to perform an action. ALWAYS call this BEFORE any monetary action (payment, order, purchase) to verify the amount is within the user's daily spend cap. Returns verdict=accept (proceed), deny (refuse politely with the reason), or ask_parent (escalate).".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "scope": {
                        "type": "string",
                        "description": "Action category. Use 'payment.spend' for any money-spending action (orders, purchases, payments).",
                        "enum": ["payment.spend"]
                    },
                    "params": {
                        "type": "object",
                        "description": "Action-specific params. For payment.spend: {amount_rmb: <integer>}.",
                        "additionalProperties": true
                    }
                },
                "required": ["scope", "params"]
            }),
        },
        ToolDescriptor {
            name: TOOL_CAP_MINT.into(),
            description: "Internal: mint a short-lived capability token. The LLM rarely needs this directly — memory.get/put and permission.check do it internally. Only call explicitly when you need a raw token for a custom flow.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "op": {
                        "type": "string",
                        "enum": ["cred_store", "cred_fetch", "memory_put", "memory_get"]
                    },
                    "params": {
                        "type": "object",
                        "properties": {
                            "service": {"type": "string"}
                        }
                    },
                    "ttl": {"type": "integer", "default": 300}
                },
                "required": ["op"]
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
