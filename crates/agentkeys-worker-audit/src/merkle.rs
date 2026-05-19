//! Minimal Merkle tree over keccak256 with OpenZeppelin-style sorted-pairs.
//!
//! Matches the on-chain `CredentialAudit.verifyEntryInRoot` algorithm so a
//! proof emitted by this module is verifiable on chain without further
//! transformation.

use sha3::{Digest, Keccak256};

pub type Bytes32 = [u8; 32];

pub fn keccak256(bytes: &[u8]) -> Bytes32 {
    let mut h = Keccak256::new();
    h.update(bytes);
    let out = h.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

fn hash_pair(a: Bytes32, b: Bytes32) -> Bytes32 {
    let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
    let mut h = Keccak256::new();
    h.update(lo);
    h.update(hi);
    let out = h.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

/// Compute the Merkle root of `leaves`. Returns the all-zero root for an
/// empty input. For odd-length levels the last node is paired with itself
/// (matches OpenZeppelin/Cosmos conventions).
pub fn merkle_root(leaves: &[Bytes32]) -> Bytes32 {
    if leaves.is_empty() {
        return [0u8; 32];
    }
    let mut level: Vec<Bytes32> = leaves.to_vec();
    while level.len() > 1 {
        let mut next = Vec::with_capacity(level.len().div_ceil(2));
        let mut i = 0;
        while i < level.len() {
            let left = level[i];
            let right = if i + 1 < level.len() { level[i + 1] } else { level[i] };
            next.push(hash_pair(left, right));
            i += 2;
        }
        level = next;
    }
    level[0]
}

/// Compute a sorted-pairs Merkle proof for leaf at `index`. Proof matches
/// the on-chain `verifyEntryInRoot` consumer.
pub fn merkle_proof(leaves: &[Bytes32], index: usize) -> Vec<Bytes32> {
    if leaves.is_empty() || index >= leaves.len() {
        return Vec::new();
    }
    let mut proof = Vec::new();
    let mut idx = index;
    let mut level: Vec<Bytes32> = leaves.to_vec();
    while level.len() > 1 {
        let sibling = if idx % 2 == 0 {
            if idx + 1 < level.len() { level[idx + 1] } else { level[idx] }
        } else {
            level[idx - 1]
        };
        proof.push(sibling);

        let mut next = Vec::with_capacity(level.len().div_ceil(2));
        let mut i = 0;
        while i < level.len() {
            let left = level[i];
            let right = if i + 1 < level.len() { level[i + 1] } else { level[i] };
            next.push(hash_pair(left, right));
            i += 2;
        }
        level = next;
        idx /= 2;
    }
    proof
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(s: &str) -> Bytes32 {
        keccak256(s.as_bytes())
    }

    #[test]
    fn root_matches_hand_computed() {
        let l0 = leaf("audit-event-0");
        let l1 = leaf("audit-event-1");
        let l2 = leaf("audit-event-2");
        let l3 = leaf("audit-event-3");
        let h01 = hash_pair(l0, l1);
        let h23 = hash_pair(l2, l3);
        let expected = hash_pair(h01, h23);
        let got = merkle_root(&[l0, l1, l2, l3]);
        assert_eq!(got, expected);
    }

    #[test]
    fn proof_verifies_with_root() {
        let leaves = vec![leaf("a"), leaf("b"), leaf("c"), leaf("d")];
        let root = merkle_root(&leaves);
        for (i, target) in leaves.iter().enumerate() {
            let proof = merkle_proof(&leaves, i);
            // Verify locally
            let mut computed = *target;
            for sibling in &proof {
                computed = hash_pair(computed, *sibling);
            }
            assert_eq!(computed, root, "leaf {i} proof failed");
        }
    }

    #[test]
    fn empty_input() {
        assert_eq!(merkle_root(&[]), [0u8; 32]);
        assert!(merkle_proof(&[], 0).is_empty());
    }

    #[test]
    fn odd_count_pairs_last_with_self() {
        let leaves = vec![leaf("a"), leaf("b"), leaf("c")];
        let root = merkle_root(&leaves);
        // Hand check: pair c with c at level 1
        let h_ab = hash_pair(leaves[0], leaves[1]);
        let h_cc = hash_pair(leaves[2], leaves[2]);
        let expected = hash_pair(h_ab, h_cc);
        assert_eq!(root, expected);
    }
}
