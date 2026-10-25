// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/crosschain/CrossChainMessageVaultSecured.sol";

contract CrossChainMessageVaultRegressionTest is Test {
    CrossChainMessageVaultSecured public ethVault;
    CrossChainMessageVaultSecured public bscVault;

    uint256 internal immutable VALIDATOR_KEY = 0x7A21B;
    address public validator;
    address public attacker = makeAddr("ATTACKER");
    address public legitimateUser = makeAddr("ALICE");

    function setUp() public {
        validator = vm.addr(VALIDATOR_KEY);

        vm.chainId(1);
        ethVault = new CrossChainMessageVaultSecured{value: 10 ether}(validator);

        vm.chainId(56);
        bscVault = new CrossChainMessageVaultSecured{value: 10 ether}(validator);
    }

    function _signWithdrawal(
        uint256 signerKey,
        CrossChainMessageVaultSecured vault,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = vault.getMessageDigest(sourceChainId, destinationChainId, recipient, amount, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Regression 1: Valid withdrawal succeeds on target chain
    function test_Regression_ValidWithdrawalSucceedsOnTargetChain() public {
        vm.chainId(1);
        uint256 amount = 3 ether;
        uint256 nonce = 0;

        bytes memory sig = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, legitimateUser, amount, nonce);

        uint256 initialBalance = legitimateUser.balance;
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount, nonce, sig);

        assertEq(legitimateUser.balance, initialBalance + amount);
        assertEq(address(ethVault).balance, 7 ether);
        assertEq(ethVault.userNonces(legitimateUser), 1);
    }

    /// @notice Regression 2: Cross-chain replay attack across chain IDs is completely blocked
    function test_Regression_CrossChainReplayFailsOnDifferentChain() public {
        vm.chainId(1);
        uint256 amount = 5 ether;
        uint256 nonce = 0;

        // Attacker observes valid signature signed for Ethereum (ChainID 1)
        bytes memory sigForEth = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, attacker, amount, nonce);

        // Attacker successfully executes on Ethereum
        vm.prank(attacker);
        ethVault.executeCrossChainWithdrawal(56, 1, attacker, amount, nonce, sigForEth);
        assertEq(address(ethVault).balance, 5 ether);

        // Attacker attempts to replay the exact same signature on BSC (ChainID 56)
        vm.chainId(56);
        uint256 bscVaultBalanceBefore = address(bscVault).balance;

        vm.startPrank(attacker);
        // Attempting to submit destinationChainId 1 on Chain 56 reverts with InvalidDestinationChain
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidDestinationChain.selector);
        bscVault.executeCrossChainWithdrawal(56, 1, attacker, amount, nonce, sigForEth);

        // Attempting to pass destinationChainId 56 with the Ethereum signature reverts with InvalidValidatorSignature
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        bscVault.executeCrossChainWithdrawal(56, 56, attacker, amount, nonce, sigForEth);
        vm.stopPrank();

        // BSC vault balance is completely preserved!
        assertEq(address(bscVault).balance, bscVaultBalanceBefore, "BSC treasury must be completely protected");
        console.log("=== REGRESSION CONFIRMED: CROSS-CHAIN REPLAY BLOCKED BY EIP-712 DOMAIN SEPARATION ===");
    }

    /// @notice Regression 3: Replay on the same chain reverts due to nonce and message ID tracking
    function test_Regression_SameChainDuplicateReplayFails() public {
        vm.chainId(1);
        uint256 amount = 2 ether;
        uint256 nonce = 0;

        bytes memory sig = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, legitimateUser, amount, nonce);

        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount, nonce, sig);

        // Immediate duplicate call reverts with MessageAlreadyExecuted
        vm.expectRevert(CrossChainMessageVaultSecured.MessageAlreadyExecuted.selector);
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount, nonce, sig);
    }

    /// @notice Fuzz test: Arbitrary chain ID mismatches are reliably rejected
    function testFuzz_DestinationChainMismatchAlwaysReverts(uint256 targetChainId, uint256 actualChainId) public {
        vm.assume(actualChainId > 0 && actualChainId < type(uint64).max);
        vm.assume(targetChainId > 0 && targetChainId != actualChainId);

        vm.chainId(actualChainId);
        CrossChainMessageVaultSecured fuzzVault = new CrossChainMessageVaultSecured{value: 1 ether}(validator);

        bytes memory dummySig = new bytes(65);

        vm.expectRevert(CrossChainMessageVaultSecured.InvalidDestinationChain.selector);
        fuzzVault.executeCrossChainWithdrawal(1, targetChainId, attacker, 1 ether, 0, dummySig);
    }
}
