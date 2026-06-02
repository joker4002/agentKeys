// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IAccount, PackedUserOperation} from "./IERC4337.sol";

/// @notice Subset of [K11Verifier] the account needs. Declared with `bytes memory`
///         so the account can pass decoded (memory) assertion bytes; the ABI
///         selector is identical to the deployed `bytes calldata` verifier.
interface IK11Verifier {
    function verifyAssertion(
        bytes32 expectedChallenge,
        bytes32 expectedRpIdHash,
        bytes memory authenticatorData,
        bytes memory clientDataJSON,
        uint256 challengeLocation,
        uint256 r,
        uint256 s,
        uint256 pubX,
        uint256 pubY
    ) external view returns (bool);
}

/// @title P256Account — ERC-4337 v0.7 master account gated by WebAuthn (K11) passkeys.
/// @notice The master authority for an operator (arch.md §6/§10), resolving #164.
///         `validateUserOp` verifies a WebAuthn assertion whose challenge **is**
///         the `userOpHash`, via the on-chain [K11Verifier]. Because `userOpHash`
///         commits the entire UserOp (callData + nonce + chainId + entryPoint),
///         the passkey signature is a provably-complete full-intent authorization
///         — no hand-rolled per-op challenge, and no secp256k1 key on any device.
/// @dev    Replay is the EntryPoint 2D nonce (no WebAuthn signCount here — see
///         the plan's Solution A rationale). Multi-passkey signer set; recovery
///         quorum is a later phase (#164 E5). The verifier (P-256) is reused from
///         the deployed K11Verifier, so no new crypto.
contract P256Account is IAccount {
    uint256 internal constant SIG_OK = 0;
    uint256 internal constant SIG_FAIL = 1;

    struct Signer {
        uint256 pubX;
        uint256 pubY;
        bytes32 rpIdHash;
        bool active;
    }

    address public immutable entryPoint;
    address public immutable k11Verifier;

    /// @notice credIdHash => authorized passkey.
    mapping(bytes32 => Signer) public signers;
    /// @notice Count of active signers; the account refuses to drop to zero.
    uint256 public activeSignerCount;

    event SignerAdded(bytes32 indexed credIdHash, uint256 pubX, uint256 pubY, bytes32 rpIdHash);
    event SignerRemoved(bytes32 indexed credIdHash);
    event Executed(address indexed dest, uint256 value, bytes data);

    error NotEntryPoint();
    error NotEntryPointOrSelf();
    error NotSelf();
    error SignerExists(bytes32 credIdHash);
    error UnknownSigner(bytes32 credIdHash);
    error LastSigner();
    error LengthMismatch();

    constructor(
        address _entryPoint,
        address _k11Verifier,
        bytes32 credIdHash,
        uint256 pubX,
        uint256 pubY,
        bytes32 rpIdHash
    ) {
        entryPoint = _entryPoint;
        k11Verifier = _k11Verifier;
        _addSigner(credIdHash, pubX, pubY, rpIdHash);
    }

    receive() external payable {}

    // ─── ERC-4337 validation ─────────────────────────────────────────────
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        // ERC-4337: a bad signature must return SIG_VALIDATION_FAILED, never
        // revert, so the EntryPoint/bundler reject the op cleanly. The on-chain
        // K11Verifier REVERTS on malformed/mismatched assertions (wrong
        // challenge/RP, missing UP/UV flags, bad clientDataJSON), and abi.decode
        // reverts on a malformed blob — so run decode+verify via an external
        // self-call wrapped in try/catch and map any failure to SIG_FAIL.
        try this.checkUserOpSignature(userOp.signature, userOpHash) returns (bool ok) {
            validationData = ok ? SIG_OK : SIG_FAIL;
        } catch {
            validationData = SIG_FAIL;
        }
        _payPrefund(missingAccountFunds);
    }

    /// @dev signature = abi.encode(credIdHash, authenticatorData, clientDataJSON,
    ///      challengeLocation, r, s). The pubkey/rpIdHash come from the stored
    ///      signer; the challenge is the userOpHash (full-intent commitment).
    ///      External + self-only so validateUserOp can try/catch its reverts and
    ///      map them to SIG_VALIDATION_FAILED. View — no state change.
    function checkUserOpSignature(bytes calldata signature, bytes32 userOpHash)
        external
        view
        returns (bool)
    {
        if (msg.sender != address(this)) revert NotSelf();
        (
            bytes32 credIdHash,
            bytes memory authenticatorData,
            bytes memory clientDataJSON,
            uint256 challengeLocation,
            uint256 r,
            uint256 s
        ) = abi.decode(signature, (bytes32, bytes, bytes, uint256, uint256, uint256));

        Signer storage signer = signers[credIdHash];
        if (!signer.active) return false;

        return IK11Verifier(k11Verifier).verifyAssertion(
            userOpHash,
            signer.rpIdHash,
            authenticatorData,
            clientDataJSON,
            challengeLocation,
            r,
            s,
            signer.pubX,
            signer.pubY
        );
    }

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds}("");
            (success); // EntryPoint reverts the op if the prefund is unmet
        }
    }

    // ─── Execution (passkey-gated via EntryPoint, or self-call from a UserOp) ──
    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireEntryPointOrSelf();
        _call(dest, value, func);
    }

    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata func
    ) external {
        _requireEntryPointOrSelf();
        if (dest.length != func.length || dest.length != value.length) revert LengthMismatch();
        for (uint256 i = 0; i < dest.length; ++i) {
            _call(dest[i], value[i], func[i]);
        }
    }

    function _call(address dest, uint256 value, bytes calldata func) internal {
        (bool ok, bytes memory ret) = dest.call{value: value}(func);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit Executed(dest, value, func);
    }

    // ─── Signer management (passkey-gated via EntryPoint/self) ────────────
    function addSigner(bytes32 credIdHash, uint256 pubX, uint256 pubY, bytes32 rpIdHash) external {
        _requireEntryPointOrSelf();
        _addSigner(credIdHash, pubX, pubY, rpIdHash);
    }

    function removeSigner(bytes32 credIdHash) external {
        _requireEntryPointOrSelf();
        if (!signers[credIdHash].active) revert UnknownSigner(credIdHash);
        if (activeSignerCount <= 1) revert LastSigner();
        signers[credIdHash].active = false;
        activeSignerCount -= 1;
        emit SignerRemoved(credIdHash);
    }

    function _addSigner(bytes32 credIdHash, uint256 pubX, uint256 pubY, bytes32 rpIdHash) internal {
        if (signers[credIdHash].active) revert SignerExists(credIdHash);
        signers[credIdHash] = Signer({pubX: pubX, pubY: pubY, rpIdHash: rpIdHash, active: true});
        activeSignerCount += 1;
        emit SignerAdded(credIdHash, pubX, pubY, rpIdHash);
    }

    function _requireEntryPointOrSelf() internal view {
        if (msg.sender != entryPoint && msg.sender != address(this)) revert NotEntryPointOrSelf();
    }
}
