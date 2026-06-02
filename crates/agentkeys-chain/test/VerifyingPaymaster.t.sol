// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerifyingPaymaster} from "../src/VerifyingPaymaster.sol";
import {PackedUserOperation} from "../src/IERC4337.sol";

contract VerifyingPaymasterTest is Test {
    address constant ENTRYPOINT = address(0xE427);
    VerifyingPaymaster pm;

    uint256 brokerPk = 0xB0B;
    address broker;
    address owner = address(0xABCD);

    uint48 constant VALID_UNTIL = 4_000_000_000;
    uint48 constant VALID_AFTER = 0;

    function setUp() public {
        broker = vm.addr(brokerPk);
        pm = new VerifyingPaymaster(ENTRYPOINT, broker, owner);
    }

    function _op() internal pure returns (PackedUserOperation memory op) {
        op.sender = address(0xACC7);
        op.nonce = 1;
        op.callData = hex"deadbeef";
        op.accountGasLimits = bytes32(uint256(1));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(uint256(2));
    }

    function _sign(uint256 pk, PackedUserOperation memory op) internal view returns (bytes memory pad) {
        bytes32 h = pm.getHash(op, VALID_UNTIL, VALID_AFTER);
        bytes32 ethH = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethH);
        bytes memory sig = abi.encodePacked(r, s, v);
        // prefix: 20 paymaster + 16 vGasLimit + 16 postOpGasLimit, then vu|va|sig
        pad = abi.encodePacked(
            address(pm), uint128(0), uint128(0), VALID_UNTIL, VALID_AFTER, sig
        );
    }

    function test_ValidSponsorship() public {
        PackedUserOperation memory op = _op();
        op.paymasterAndData = _sign(brokerPk, op);
        vm.prank(ENTRYPOINT);
        (, uint256 validationData) = pm.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(validationData & 1, 0, "broker-signed -> sponsored (sigFailed bit clear)");
        assertEq((validationData >> 160) & ((1 << 48) - 1), VALID_UNTIL, "validUntil packed");
    }

    function test_RejectsWrongSigner() public {
        PackedUserOperation memory op = _op();
        op.paymasterAndData = _sign(0xBADBAD, op); // not the broker key
        vm.prank(ENTRYPOINT);
        (, uint256 validationData) = pm.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(validationData & 1, 1, "wrong signer -> sigFailed bit set");
    }

    function test_RejectsTamperedOp() public {
        PackedUserOperation memory op = _op();
        op.paymasterAndData = _sign(brokerPk, op);
        op.callData = hex"c0ffee"; // tamper after signing → hash mismatch
        vm.prank(ENTRYPOINT);
        (, uint256 validationData) = pm.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(validationData & 1, 1, "tampered op -> sigFailed");
    }

    function test_OnlyEntryPoint() public {
        PackedUserOperation memory op = _op();
        op.paymasterAndData = _sign(brokerPk, op);
        vm.expectRevert(VerifyingPaymaster.NotEntryPoint.selector);
        pm.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_SetBrokerSigner_OnlyOwner() public {
        vm.expectRevert(VerifyingPaymaster.NotOwner.selector);
        pm.setBrokerSigner(address(0x1234));

        vm.prank(owner);
        pm.setBrokerSigner(address(0x1234));
        assertEq(pm.brokerSigner(), address(0x1234));
    }

    function test_RejectsShortPaymasterData() public {
        PackedUserOperation memory op = _op();
        op.paymasterAndData = abi.encodePacked(address(pm), uint128(0), uint128(0)); // no vu/va/sig
        vm.prank(ENTRYPOINT);
        vm.expectRevert(VerifyingPaymaster.BadPaymasterDataLength.selector);
        pm.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }
}
