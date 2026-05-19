// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {P256Verifier} from "../src/P256Verifier.sol";
import {K11Verifier} from "../src/K11Verifier.sol";

/// @title K11VerifierTest — smoke tests for challenge-binding logic.
/// @dev   Full end-to-end (real WebAuthn assertion bytes) is tested via the
///        Rust integration tests in `crates/agentkeys-cli/tests/`, where we can
///        actually run navigator.credentials.get() against a software P-256
///        authenticator and feed the result into the contract.
///
///        Here we test:
///          - base64url encoding is correct (using a known fixture).
///          - challenge mismatch reverts as expected.
///          - malformed inputs revert with the right errors.
contract K11VerifierTest is Test {
    K11Verifier verifier;

    function setUp() public {
        P256Verifier p256 = new P256Verifier();
        verifier = new K11Verifier(address(p256));
    }

    function test_challenge_mismatch_reverts() public {
        bytes32 expectedChallenge = keccak256("op:1");
        bytes memory authData = new bytes(37);
        // clientDataJSON shape mirroring a real WebAuthn payload, but with a
        // WRONG challenge embedded.
        // base64url("zzz...") ≠ base64url(expectedChallenge).
        string memory wrongJSON =
            '{"type":"webauthn.get","challenge":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","origin":"https://localhost"}';
        uint256 challengeLocation = 36; // byte offset of the value's first char

        vm.expectRevert(K11Verifier.ChallengeMismatch.selector);
        verifier.verifyAssertion(
            expectedChallenge,
            authData,
            bytes(wrongJSON),
            challengeLocation,
            1,
            1,
            1,
            1
        );
    }

    function test_short_authData_reverts() public {
        bytes32 expectedChallenge = keccak256("op:1");
        bytes memory shortAuthData = new bytes(36); // < 37 = invalid
        string memory json = '{"type":"webauthn.get","challenge":"aaa"}';
        vm.expectRevert(K11Verifier.MalformedAuthenticatorData.selector);
        verifier.verifyAssertion(
            expectedChallenge, shortAuthData, bytes(json), 36, 1, 1, 1, 1
        );
    }

    function test_clientDataJSON_too_short_reverts() public {
        bytes32 expectedChallenge = keccak256("op:1");
        bytes memory authData = new bytes(37);
        // 36 bytes total - challengeLocation 36 + 43 > 36 - revert
        string memory tooShort = "012345678901234567890123456789012345";
        vm.expectRevert(K11Verifier.MalformedClientDataJSON.selector);
        verifier.verifyAssertion(
            expectedChallenge, authData, bytes(tooShort), 0, 1, 1, 1, 1
        );
    }

    function test_readSignCount() public view {
        bytes memory authData = new bytes(37);
        // 33..37 are big-endian uint32. Set counter = 0x12345678.
        authData[33] = 0x12;
        authData[34] = 0x34;
        authData[35] = 0x56;
        authData[36] = 0x78;
        uint32 count = verifier.readSignCount(authData);
        assertEq(count, 0x12345678);
    }

    function test_readSignCount_zero() public view {
        bytes memory authData = new bytes(37);
        // Default-zero authData → counter 0.
        uint32 count = verifier.readSignCount(authData);
        assertEq(count, 0);
    }

    function test_base64_encoding_of_zero_challenge() public {
        // bytes32(0) = 0x000...000 (32 bytes of 0)
        // base64url encoding: 32 bytes of 0 → 43 chars of 'A'
        // Verify by constructing a valid clientDataJSON with 43 'A's at the
        // challenge location and checking it does NOT revert with
        // ChallengeMismatch (it should revert on P-256 verify instead since
        // r/s/pubkey are bogus).
        bytes32 expectedChallenge = bytes32(0);
        bytes memory authData = new bytes(37);
        // 43 A's = base64url(32 zero bytes)
        string memory goodJSON =
            '{"type":"webauthn.get","challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","origin":"https://localhost"}';
        uint256 challengeLocation = 36;

        // Should NOT revert with ChallengeMismatch — encoding matches.
        // P-256 verify will return false on bogus inputs but won't revert.
        bool ok = verifier.verifyAssertion(
            expectedChallenge, authData, bytes(goodJSON), challengeLocation, 1, 1, 1, 1
        );
        assertFalse(ok); // bogus sig
    }
}
