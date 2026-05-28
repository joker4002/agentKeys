use std::fmt;

use serde::{Deserialize, Serialize};

pub mod provision;

pub use provision::{ProvisionErrorCode, ProvisionEvent, TripwireKind};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct WalletAddress(pub String);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct InboxAddress(pub String);

impl fmt::Display for InboxAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Session {
    pub token: String,
    pub wallet: WalletAddress,
    pub scope: Option<Scope>,
    pub created_at: u64,
    pub ttl_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Scope {
    pub services: Vec<ServiceName>,
    pub read_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct ServiceName(pub String);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum AuthToken {
    GoogleOAuth(String),
    Passkey(Vec<u8>),
    Mock(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum RecoveryMethod {
    MasterApproval,
    Passkey,
    Email,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairCode(pub String);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthRequestId(pub String);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum AgentIdentity {
    Alias(String),
    Email(String),
    Ens(String),
    WalletAddress(WalletAddress),
    /// OAuth2 identity from a third-party provider. `provider` is one of
    /// `"google"`, `"github"`, `"apple"` (v0 ships only `"google"`).
    /// `sub` is the provider's stable user id (NOT the email — emails can
    /// migrate). Stage 7 issue #64 adds this variant; pre-existing
    /// AgentIdentity consumers continue to work unchanged because every
    /// other variant remains.
    OAuth2 {
        provider: String,
        sub: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum AuthRequestType {
    Pair {
        requested_scope: Scope,
    },
    Recover {
        agent_identity: AgentIdentity,
        new_daemon_pubkey: Vec<u8>,
    },
    ScopeChange {
        agent_id: WalletAddress,
        new_scope: Scope,
    },
    HighValueRelease {
        agent_id: WalletAddress,
        service: ServiceName,
        estimated_cost_cents: u64,
    },
    KeyRotate {
        agent_id: WalletAddress,
        new_pubkey: Vec<u8>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicKey(pub Vec<u8>);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistrationToken(pub String);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairPayload(pub Vec<u8>);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedPairPayload(pub Vec<u8>);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanonicalBytes(pub Vec<u8>);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenedAuthRequest {
    pub id: AuthRequestId,
    pub otp: String,
    pub pair_code: PairCode,
    pub ttl_seconds: u64,
    pub nonce_hash: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthRequest {
    pub id: AuthRequestId,
    pub request_type: AuthRequestType,
    pub child_pubkey: PublicKey,
    pub otp: String,
    pub created_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedAuthDecision {
    pub request_id: AuthRequestId,
    pub approved: bool,
    pub signature: Vec<u8>,
    pub session: Option<Session>,
    pub wallet: Option<WalletAddress>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AuditFilter {
    pub owner: Option<WalletAddress>,
    pub agent: Option<WalletAddress>,
    pub service: Option<ServiceName>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEvent {
    pub owner: WalletAddress,
    pub agent: WalletAddress,
    pub service: ServiceName,
    pub action: String,
    pub result: String,
    pub timestamp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum PaymentLayer {
    SystemGas,
    ServicePayment,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Amount {
    pub value: u64,
    pub decimals: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransactionReceipt {
    pub tx_hash: String,
    pub amount: Amount,
    pub layer: PaymentLayer,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SpendFilter {
    pub wallet: Option<WalletAddress>,
    pub layer: Option<PaymentLayer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpendEvent {
    pub wallet: WalletAddress,
    pub amount: Amount,
    pub layer: PaymentLayer,
    pub reason: String,
    pub timestamp: u64,
}

/// v0 memory namespace (issue #108, `docs/agent-iam-strategy.md` §3.5).
///
/// Namespaces are the ORTHOGONAL semantic dimension layered over the
/// 4 structural memory types — they scope which life-context a memory
/// item belongs to. A cap-token carries a `namespaces_allowed` claim;
/// the memory worker filters reads/writes by deterministic string-set
/// membership (no LLM, no fuzzy matching). The list is intentionally
/// small in v0 (4 fixed); user-defined namespaces land in a later phase
/// with the delegation/ACL work.
///
/// The serde rename keeps the wire form a lowercase string so the cap
/// payload's `namespaces_allowed: ["travel"]` and the put/get envelope's
/// `namespace: "travel"` are plain strings, not tagged enums.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Namespace {
    Personal,
    Family,
    Work,
    Travel,
}

impl Namespace {
    /// The fixed v0 set, in canonical order.
    pub const ALL: [Namespace; 4] = [
        Namespace::Personal,
        Namespace::Family,
        Namespace::Work,
        Namespace::Travel,
    ];

    /// Lowercase wire spelling — matches the serde rename so callers can
    /// build the cap claim / envelope field without serializing.
    pub fn as_str(self) -> &'static str {
        match self {
            Namespace::Personal => "personal",
            Namespace::Family => "family",
            Namespace::Work => "work",
            Namespace::Travel => "travel",
        }
    }

    /// Parse a wire string into a known namespace. Returns `None` for any
    /// name outside the v0 set so callers can reject typos with a 400
    /// (a typo'd namespace must NOT silently filter everything).
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|ns| ns.as_str() == name)
    }

    /// True when `name` is one of the v0 namespaces.
    pub fn is_valid(name: &str) -> bool {
        Self::parse(name).is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_serialize_roundtrip() {
        let session = Session {
            token: "test-token".into(),
            wallet: WalletAddress("0x1234".into()),
            scope: Some(Scope {
                services: vec![ServiceName("openrouter".into())],
                read_only: true,
            }),
            created_at: 1000,
            ttl_seconds: 3600,
        };
        let json = serde_json::to_string(&session).unwrap();
        let back: Session = serde_json::from_str(&json).unwrap();
        assert_eq!(session, back);
    }

    #[test]
    fn recovery_method_serialize_roundtrip() {
        for method in [
            RecoveryMethod::MasterApproval,
            RecoveryMethod::Passkey,
            RecoveryMethod::Email,
        ] {
            let json = serde_json::to_string(&method).unwrap();
            let back: RecoveryMethod = serde_json::from_str(&json).unwrap();
            assert_eq!(method, back);
        }
    }

    #[test]
    fn agent_identity_variants() {
        let alias = AgentIdentity::Alias("my-bot".into());
        let email = AgentIdentity::Email("bot@example.com".into());
        let ens = AgentIdentity::Ens("mybot.eth".into());
        let wallet = AgentIdentity::WalletAddress(WalletAddress("0xabc".into()));

        for variant in [&alias, &email, &ens, &wallet] {
            let json = serde_json::to_string(variant).unwrap();
            let back: AgentIdentity = serde_json::from_str(&json).unwrap();
            assert_eq!(variant, &back);
        }
    }

    #[test]
    fn namespace_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&Namespace::Personal).unwrap(),
            "\"personal\""
        );
        assert_eq!(
            serde_json::to_string(&Namespace::Travel).unwrap(),
            "\"travel\""
        );
    }

    #[test]
    fn namespace_parse_accepts_v0_set_rejects_typos() {
        for ns in Namespace::ALL {
            assert_eq!(Namespace::parse(ns.as_str()), Some(ns));
            assert!(Namespace::is_valid(ns.as_str()));
        }
        // `profile` is a memory TYPE, not a namespace — must be rejected.
        assert_eq!(Namespace::parse("profile"), None);
        assert!(!Namespace::is_valid("Travel")); // case-sensitive
        assert!(!Namespace::is_valid(""));
    }
}
