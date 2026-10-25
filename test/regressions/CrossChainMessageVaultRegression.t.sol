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

    /// @notice Regression 4: Rejection of signature intended for a different verifier contract on the same chain
    function test_Regression_CrossContractReplayFailsOnSameChain() public {
        vm.chainId(1);
        CrossChainMessageVaultSecured secondVault = new CrossChainMessageVaultSecured{value: 10 ether}(validator);

        uint256 amount = 1 ether;
        uint256 nonce = 0;

        // Signature created specifically for ethVault
        bytes memory sigForEthVault = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, attacker, amount, nonce);

        // Attacker attempts to replay this signature on secondVault
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        secondVault.executeCrossChainWithdrawal(56, 1, attacker, amount, nonce, sigForEthVault);
    }

    /// @notice Regression 5: Any payload alteration (recipient, amount) invalidates ECDSA recovery
    function test_Regression_TamperedPayloadReverts() public {
        vm.chainId(1);
        uint256 amount = 2 ether;
        uint256 nonce = 0;

        bytes memory sig = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, legitimateUser, amount, nonce);

        // Tamper with recipient
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        ethVault.executeCrossChainWithdrawal(56, 1, attacker, amount, nonce, sig);

        // Tamper with amount
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount + 1 ether, nonce, sig);
    }

    /// @notice Regression 6: Unauthorized signer is rejected
    function test_Regression_UnauthorizedSignerReverts() public {
        vm.chainId(1);
        uint256 fakeValidatorKey = 0xBADBEEF;
        uint256 amount = 1 ether;
        uint256 nonce = 0;

        bytes memory sig = _signWithdrawal(fakeValidatorKey, ethVault, 56, 1, attacker, amount, nonce);

        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        ethVault.executeCrossChainWithdrawal(56, 1, attacker, amount, nonce, sig);
    }

    /// @notice Regression 7: Malformed signature length reverts with ECDSA length error
    function test_Regression_MalformedSignatureReverts() public {
        vm.chainId(1);
        bytes memory shortSig = new bytes(64); // Invalid length (requires 65)

        vm.expectRevert();
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, 1 ether, 0, shortSig);
    }

    /// @notice Regression 8: Reverted transaction does not mutate nonce; subsequent valid transaction succeeds
    function test_Regression_FailedAttemptDoesNotAdvanceNonce() public {
        vm.chainId(1);
        uint256 amount = 1 ether;

        assertEq(ethVault.userNonces(legitimateUser), 0);

        // Signature from unauthorized key reverts with InvalidValidatorSignature
        bytes memory unauthorizedSig = _signWithdrawal(0xBADBEEF, ethVault, 56, 1, legitimateUser, amount, 0);
        vm.expectRevert(CrossChainMessageVaultSecured.InvalidValidatorSignature.selector);
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount, 0, unauthorizedSig);

        // Nonce is strictly preserved at 0
        assertEq(ethVault.userNonces(legitimateUser), 0, "Failed attempt must not advance nonce");

        // Now submit valid signature with nonce 0
        bytes memory validSig = _signWithdrawal(VALIDATOR_KEY, ethVault, 56, 1, legitimateUser, amount, 0);
        ethVault.executeCrossChainWithdrawal(56, 1, legitimateUser, amount, 0, validSig);

        // Nonce is now advanced to 1
        assertEq(ethVault.userNonces(legitimateUser), 1);
    }
}
