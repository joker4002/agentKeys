// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {P256Account} from "../src/P256Account.sol";
import {P256AccountFactory} from "../src/P256AccountFactory.sol";
import {PackedUserOperation} from "../src/IERC4337.sol";

contract Counter {
    uint256 public number;

    function increment() external {
        number += 1;
    }
}

/// @dev Stand-in for the deployed K11Verifier. Real WebAuthn/P-256 verification
///      is covered by K11Verifier.t.sol / P256Verifier.t.sol and the Heima
///      mainnet spike (#164 plan §1); here we exercise the account's LOGIC.
contract MockK11Verifier {
    bool public result = true;

    function setResult(bool r) external {
        result = r;
    }

    function verifyAssertion(
        bytes32,
        bytes32,
        bytes memory,
        bytes memory,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external view returns (bool) {
        return result;
    }
}

contract P256AccountTest is Test {
    address constant ENTRYPOINT = address(0xE427);
    MockK11Verifier k11;
    P256AccountFactory factory;
    Counter counter;

    bytes32 constant CRED = keccak256("cred-1");
    bytes32 constant CRED2 = keccak256("cred-2");
    uint256 constant PUBX = uint256(keccak256("pubx"));
    uint256 constant PUBY = uint256(keccak256("puby"));
    bytes32 constant RPID = keccak256("litentry.org");

    function setUp() public {
        k11 = new MockK11Verifier();
        factory = new P256AccountFactory(ENTRYPOINT, address(k11));
        counter = new Counter();
    }

    function _deploy() internal returns (P256Account) {
        return P256Account(payable(factory.createAccount(CRED, PUBX, PUBY, RPID, bytes32(0))));
    }

    function _op(bytes32 cred) internal pure returns (PackedUserOperation memory op) {
        op.signature = abi.encode(cred, hex"aa", hex"bb", uint256(0), uint256(1), uint256(2));
    }

    function test_FactoryDeterministicAndIdempotent() public {
        address predicted = factory.getAddress(CRED, PUBX, PUBY, RPID, bytes32(0));
        address a = factory.createAccount(CRED, PUBX, PUBY, RPID, bytes32(0));
        assertEq(a, predicted, "address must match prediction");
        assertEq(factory.createAccount(CRED, PUBX, PUBY, RPID, bytes32(0)), a, "idempotent");
        assertGt(a.code.length, 0, "deployed");
    }

    function test_FactoryAddressDependsOnPasskey() public view {
        assertTrue(
            factory.getAddress(CRED, PUBX, PUBY, RPID, bytes32(0))
                != factory.getAddress(CRED, PUBX + 1, PUBY, RPID, bytes32(0)),
            "different passkey -> different address"
        );
    }

    function test_InitialSigner() public {
        P256Account acct = _deploy();
        assertEq(acct.activeSignerCount(), 1);
        (uint256 x, uint256 y, bytes32 rp, bool active) = acct.signers(CRED);
        assertEq(x, PUBX);
        assertEq(y, PUBY);
        assertEq(rp, RPID);
        assertTrue(active);
    }

    function test_ValidateUserOp_Success() public {
        P256Account acct = _deploy();
        k11.setResult(true);
        vm.prank(ENTRYPOINT);
        assertEq(acct.validateUserOp(_op(CRED), bytes32(uint256(0x1234)), 0), 0);
    }

    function test_ValidateUserOp_BadSig() public {
        P256Account acct = _deploy();
        k11.setResult(false);
        vm.prank(ENTRYPOINT);
        assertEq(acct.validateUserOp(_op(CRED), bytes32(uint256(0x1234)), 0), 1);
    }

    function test_ValidateUserOp_UnknownSigner() public {
        P256Account acct = _deploy();
        vm.prank(ENTRYPOINT);
        assertEq(acct.validateUserOp(_op(CRED2), bytes32(uint256(0x1234)), 0), 1);
    }

    function test_ValidateUserOp_OnlyEntryPoint() public {
        P256Account acct = _deploy();
        vm.expectRevert(P256Account.NotEntryPoint.selector);
        acct.validateUserOp(_op(CRED), bytes32(uint256(0x1234)), 0);
    }

    function test_Execute_FromEntryPoint() public {
        P256Account acct = _deploy();
        vm.prank(ENTRYPOINT);
        acct.execute(address(counter), 0, abi.encodeWithSelector(Counter.increment.selector));
        assertEq(counter.number(), 1);
    }

    function test_Execute_Unauthorized() public {
        P256Account acct = _deploy();
        vm.expectRevert(P256Account.NotEntryPointOrSelf.selector);
        acct.execute(address(counter), 0, abi.encodeWithSelector(Counter.increment.selector));
    }

    function test_ExecuteBatch() public {
        P256Account acct = _deploy();
        address[] memory dest = new address[](2);
        uint256[] memory val = new uint256[](2);
        bytes[] memory fn = new bytes[](2);
        dest[0] = address(counter);
        dest[1] = address(counter);
        fn[0] = abi.encodeWithSelector(Counter.increment.selector);
        fn[1] = abi.encodeWithSelector(Counter.increment.selector);
        vm.prank(ENTRYPOINT);
        acct.executeBatch(dest, val, fn);
        assertEq(counter.number(), 2);
    }

    function test_AddSigner_GatedAndUsable() public {
        P256Account acct = _deploy();
        vm.expectRevert(P256Account.NotEntryPointOrSelf.selector);
        acct.addSigner(CRED2, PUBX, PUBY, RPID);

        vm.prank(ENTRYPOINT);
        acct.addSigner(CRED2, PUBX, PUBY, RPID);
        assertEq(acct.activeSignerCount(), 2);

        k11.setResult(true);
        vm.prank(ENTRYPOINT);
        assertEq(acct.validateUserOp(_op(CRED2), bytes32(uint256(1)), 0), 0, "new passkey validates");
    }

    function test_RemoveSigner_LockoutProtection() public {
        P256Account acct = _deploy();
        vm.prank(ENTRYPOINT);
        vm.expectRevert(P256Account.LastSigner.selector);
        acct.removeSigner(CRED);
    }

    function test_RemoveSigner_Works() public {
        P256Account acct = _deploy();
        vm.startPrank(ENTRYPOINT);
        acct.addSigner(CRED2, PUBX, PUBY, RPID);
        acct.removeSigner(CRED);
        vm.stopPrank();
        assertEq(acct.activeSignerCount(), 1);
        vm.prank(ENTRYPOINT);
        assertEq(acct.validateUserOp(_op(CRED), bytes32(uint256(1)), 0), 1, "removed signer rejected");
    }

    function test_PayPrefund() public {
        P256Account acct = _deploy();
        vm.deal(address(acct), 1 ether);
        k11.setResult(true);
        uint256 epBefore = ENTRYPOINT.balance;
        vm.prank(ENTRYPOINT);
        acct.validateUserOp(_op(CRED), bytes32(uint256(1)), 0.1 ether);
        assertEq(ENTRYPOINT.balance, epBefore + 0.1 ether, "prefund forwarded to EntryPoint");
    }
}
