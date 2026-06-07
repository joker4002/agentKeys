//! #225 / #164 E7 — assemble the **sponsored agent-accept UserOp**.
//!
//! Ties the two halves that already exist into one complete, ready-to-sign
//! `PackedUserOperation`:
//!   - the **intent** — `agentkeys_core::erc4337::accept_batch_calldata` (the atomic
//!     `executeBatch([registerAgentDevice, setScope])`, P.2 + P.3);
//!   - the **sponsorship** — the broker EIP-191 co-signs the `VerifyingPaymaster`
//!     `getHash` (the J1-gated Sybil gate = gas-free), via [`crate::sponsor`].
//!
//! Output: the op with `paymasterAndData` filled, plus the `userOpHash` the master
//! passkey (K11) signs and the `getHash` the broker signed. **Pure** (takes the
//! broker key, no chain I/O): the caller fetches the on-chain 2D nonce + gas/fee
//! params and supplies them; submission (`EntryPoint.handleOps`) is the I/O step
//! that consumes [`AssembledAcceptUserOp::user_op`] once the account signature is
//! attached.
//!
//! Division of labour (unchanged from #200): browser/daemon K11-signs the
//! `userOpHash`; the broker co-signs the paymaster `getHash`; submission is Stage B.

use crate::sponsor::{assemble_paymaster_and_data, broker_cosign, pack_u128_pair, PackedUserOp};
use agentkeys_core::erc4337::{accept_batch_calldata, AgentRegister, ScopeGrant};
use anyhow::Result;
use k256::ecdsa::SigningKey;

/// Everything the composer needs that isn't the broker key. Chain-derived values
/// (nonce, gas, fees, validity window, addresses) are inputs — nothing hardcoded;
/// the caller reads them on-chain and passes them in.
pub struct AcceptUserOpParams<'a> {
    pub entry_point: [u8; 20],
    pub chain_id: u64,

    /// The operator's ERC-4337 P-256 master account (the `sender`).
    pub master_account: [u8; 20],
    /// `SidecarRegistry` (target of the `registerAgentDevice` inner call).
    pub registry: [u8; 20],
    /// `AgentKeysScope` (target of the `setScope` inner call).
    pub scope: [u8; 20],
    /// EntryPoint v0.7 2D nonce for `master_account` (read on-chain by the caller).
    pub nonce: [u8; 32],

    /// `verificationGasLimit(16) ‖ callGasLimit(16)` — use [`pack_u128_pair`].
    pub account_gas_limits: [u8; 32],
    pub pre_verification_gas: [u8; 32],
    /// `maxPriorityFeePerGas(16) ‖ maxFeePerGas(16)` — use [`pack_u128_pair`].
    pub gas_fees: [u8; 32],

    pub paymaster: [u8; 20],
    pub paymaster_verification_gas_limit: u128,
    pub paymaster_post_op_gas_limit: u128,
    pub valid_until: u64,
    pub valid_after: u64,
    /// The broker EOA the `VerifyingPaymaster` trusts (recovers from the co-sign).
    pub broker_signer: [u8; 20],

    pub register: &'a AgentRegister,
    pub grant: &'a ScopeGrant,
}

/// The assembled op + the two digests. `user_op.signature` is still empty — the
/// account (K11) signs `user_op_hash` and the caller sets it before submit.
pub struct AssembledAcceptUserOp {
    pub user_op: PackedUserOp,
    /// The account (master passkey / K11) signs THIS — `EntryPoint.getUserOpHash`.
    pub user_op_hash: [u8; 32],
    /// The broker signed THIS — `VerifyingPaymaster.getHash` (returned for audit).
    pub paymaster_get_hash: [u8; 32],
}

/// Assemble the sponsored accept UserOp: build the batch callData, co-sign the
/// paymaster, fill `paymasterAndData`, and compute the `userOpHash`.
///
/// The paymaster `getHash` commits `paymasterAndData[20:52]` (the gas limits), so
/// we set those bytes BEFORE hashing — a provisional `paymaster ‖ gasWord` — then
/// rebuild `paymasterAndData` with the real broker signature appended. The two
/// always agree on the gas word, which is what the on-chain `getHash` re-derives.
pub fn assemble_accept_userop(
    p: &AcceptUserOpParams,
    broker_sk: &SigningKey,
) -> Result<AssembledAcceptUserOp> {
    let call_data = accept_batch_calldata(&p.registry, &p.scope, p.register, p.grant);

    let mut user_op = PackedUserOp {
        sender: p.master_account,
        nonce: p.nonce,
        init_code: Vec::new(),
        call_data,
        account_gas_limits: p.account_gas_limits,
        pre_verification_gas: p.pre_verification_gas,
        gas_fees: p.gas_fees,
        paymaster_and_data: Vec::new(),
        signature: Vec::new(),
    };

    // Provisional paymasterAndData = paymaster(20) ‖ gasWord(32); exposes [20:52]
    // (the gas word) so paymaster_get_hash reads the limits the broker is approving.
    let gas_word = pack_u128_pair(
        p.paymaster_verification_gas_limit,
        p.paymaster_post_op_gas_limit,
    );
    let mut provisional = Vec::with_capacity(52);
    provisional.extend_from_slice(&p.paymaster);
    provisional.extend_from_slice(&gas_word);
    user_op.paymaster_and_data = provisional;

    let paymaster_get_hash = user_op.paymaster_get_hash(
        p.valid_until,
        p.valid_after,
        &p.paymaster,
        &p.broker_signer,
        p.chain_id,
    );
    let broker_sig = broker_cosign(&paymaster_get_hash, broker_sk)?;

    // Final paymasterAndData with the real co-signature appended.
    user_op.paymaster_and_data = assemble_paymaster_and_data(
        &p.paymaster,
        p.paymaster_verification_gas_limit,
        p.paymaster_post_op_gas_limit,
        p.valid_until,
        p.valid_after,
        &broker_sig,
    )?;

    let user_op_hash = user_op.user_op_hash(&p.entry_point, p.chain_id);

    Ok(AssembledAcceptUserOp {
        user_op,
        user_op_hash,
        paymaster_get_hash,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use agentkeys_core::device_crypto::{ecrecover_eip191, evm_address};
    use k256::ecdsa::VerifyingKey;

    fn b32(x: u8) -> [u8; 32] {
        [x; 32]
    }

    fn sample_register() -> AgentRegister {
        AgentRegister {
            device_key_hash: b32(0x11),
            operator_omni: b32(0x22),
            actor_omni: b32(0x33),
            link_code_redemption: hex::decode("deadbeef").unwrap(),
            agent_pop_sig: vec![0x55; 65],
        }
    }

    fn sample_grant() -> ScopeGrant {
        ScopeGrant {
            services: vec![b32(0xaa), b32(0xbb)],
            read_only: true,
            max_per_call: 1000,
            max_per_period: 2000,
            max_total: 0,
            period_seconds: 86400,
        }
    }

    fn params<'a>(
        reg: &'a AgentRegister,
        grant: &'a ScopeGrant,
        broker_signer: [u8; 20],
    ) -> AcceptUserOpParams<'a> {
        AcceptUserOpParams {
            entry_point: [0x66; 20],
            chain_id: 212_013,
            master_account: [0x99; 20],
            registry: {
                let mut a = [0u8; 20];
                a[19] = 0xa1;
                a
            },
            scope: {
                let mut a = [0u8; 20];
                a[19] = 0xa2;
                a
            },
            nonce: {
                let mut n = [0u8; 32];
                n[31] = 7;
                n
            },
            account_gas_limits: pack_u128_pair(300_000, 200_000),
            pre_verification_gas: {
                let mut w = [0u8; 32];
                w[28..].copy_from_slice(&60_000u32.to_be_bytes());
                w
            },
            gas_fees: pack_u128_pair(1_000_000_000, 2_000_000_000),
            paymaster: [0x55; 20],
            paymaster_verification_gas_limit: 80_000,
            paymaster_post_op_gas_limit: 40_000,
            valid_until: 9_999_999_999,
            valid_after: 0,
            broker_signer,
            register: reg,
            grant,
        }
    }

    #[test]
    fn calldata_is_the_accept_batch_and_sender_is_the_master() {
        let sk = SigningKey::random(&mut rand_core::OsRng);
        let broker_addr = evm_address(&VerifyingKey::from(&sk));
        let broker_bytes: [u8; 20] = hex::decode(broker_addr.trim_start_matches("0x"))
            .unwrap()
            .try_into()
            .unwrap();
        let reg = sample_register();
        let grant = sample_grant();
        let p = params(&reg, &grant, broker_bytes);
        let out = assemble_accept_userop(&p, &sk).unwrap();

        assert_eq!(out.user_op.sender, p.master_account);
        // The callData is exactly the atomic accept batch.
        assert_eq!(
            out.user_op.call_data,
            accept_batch_calldata(&p.registry, &p.scope, &reg, &grant)
        );
        // Signature is left for the account (K11) to fill.
        assert!(out.user_op.signature.is_empty());
        // userOpHash is deterministic.
        assert_eq!(
            out.user_op_hash,
            out.user_op.user_op_hash(&p.entry_point, p.chain_id)
        );
    }

    #[test]
    fn paymaster_and_data_carries_a_broker_cosign_over_the_get_hash() {
        let sk = SigningKey::random(&mut rand_core::OsRng);
        let broker_addr = evm_address(&VerifyingKey::from(&sk));
        let broker_bytes: [u8; 20] = hex::decode(broker_addr.trim_start_matches("0x"))
            .unwrap()
            .try_into()
            .unwrap();
        let reg = sample_register();
        let grant = sample_grant();
        let p = params(&reg, &grant, broker_bytes);
        let out = assemble_accept_userop(&p, &sk).unwrap();

        // Layout: paymaster(20) ‖ vgl(16) ‖ postOp(16) ‖ validUntil(6) ‖ validAfter(6) ‖ sig(65).
        let pad = &out.user_op.paymaster_and_data;
        assert_eq!(pad.len(), 20 + 16 + 16 + 6 + 6 + 65);
        assert_eq!(&pad[0..20], &p.paymaster);
        // The trailing 65 bytes are the broker co-sign; it recovers to the broker
        // EOA under the SAME EIP-191(getHash) the VerifyingPaymaster checks.
        // Layout offsets: paymaster 0..20, vgl 20..36, postOp 36..52,
        // validUntil 52..58, validAfter 58..64, sig 64..129.
        let sig_hex = format!("0x{}", hex::encode(&pad[64..129]));
        let recovered = ecrecover_eip191(&out.paymaster_get_hash, &sig_hex).unwrap();
        assert_eq!(recovered, broker_addr);
    }

    #[test]
    fn changing_the_grant_changes_the_user_op_hash() {
        let sk = SigningKey::random(&mut rand_core::OsRng);
        let broker_addr = evm_address(&VerifyingKey::from(&sk));
        let broker_bytes: [u8; 20] = hex::decode(broker_addr.trim_start_matches("0x"))
            .unwrap()
            .try_into()
            .unwrap();
        let reg = sample_register();
        let grant_a = sample_grant();
        let mut grant_b = sample_grant();
        grant_b.read_only = false; // a different scope ⇒ different intent ⇒ different hash.

        let h_a = assemble_accept_userop(&params(&reg, &grant_a, broker_bytes), &sk)
            .unwrap()
            .user_op_hash;
        let h_b = assemble_accept_userop(&params(&reg, &grant_b, broker_bytes), &sk)
            .unwrap()
            .user_op_hash;
        assert_ne!(h_a, h_b);
    }
}
