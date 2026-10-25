# Security Audit Report Template

---

## Finding Summary

| Field | Detail |
| :--- | :--- |
| **Finding ID** | `[SEC-CATEGORY-001]` |
| **Title** | `[Concise Vulnerability Description]` |
| **Severity** | `Critical` / `High` / `Medium` / `Low` / `Informational` |
| **CVSS v3.1 Score** | `[Base Score, e.g., 8.8 (CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H)]` |
| **Status** | `Confirmed & Mitigated` / `Confirmed Unmitigated` / `Informational` |
| **Target Component** | `[Contract Name or Protocol Module]` |
| **Affected Source File** | `[src/path/to/Contract.sol#Lxx-Lyy]` |
| **Fixed Source File** | `[src/path/to/ContractFixed.sol#Lxx-Lyy]` |
| **Exploit Test File** | `[test/path/to/ExploitTest.t.sol]` |
| **Regression Test File** | `[test/path/to/RegressionTest.t.sol]` |

---

## 1. Vulnerability Overview & Root Cause

### 1.1 Description
[Detailed explanation of the flaw, the architectural context, and the underlying code mechanism that allows the issue to occur.]

### 1.2 Root Cause Analysis
[Code-level analysis pointing to specific lines of code, missing state checks, reordering of reads/writes, or absent modifiers.]

---

## 2. Threat Model & Attack Preconditions

### 2.1 Threat Actor Profile
- **Attacker Capabilities:** [e.g., Unprivileged external actor, any EVM account, flash loan borrower]
- **Prerequisites / Capital Requirements:** [e.g., Requires 1 wei of initial deposit, or requires flash-borrowing liquidity]

### 2.2 Attack Surface
- **Entry Points:** [e.g., `swap(uint256,uint256,address,bytes)`, `executeCrossChainWithdrawal(...)`]
- **Trust Assumptions Violated:** [e.g., Assumption that callback will return borrowed tokens or that reserves cannot be mutated mid-execution]

---

## 3. Step-by-Step Attack Scenario

1. **Step 1:** [Attacker action, parameters passed]
2. **Step 2:** [State transition, intermediary values]
3. **Step 3:** [Exploitation of flaw, invariant breach]
4. **Step 4:** [Funds extraction / state compromise]

---

## 4. Minimal Reproducible Proof of Concept (PoC)

### 4.1 Test Code Reference
[Direct link or excerpt from the verified Foundry test reproducing the exploit.]

### 4.2 Exact Execution Command
```bash
forge test -vvv --match-test <test_name>
```

### 4.3 Observed Command Output & Console Logs
```text
[Paste exact, un-fabricated output from the Foundry test run]
```

---

## 5. Realistic Impact & Risk Assessment

- **Affected Assets:** [e.g., Entire liquidity pool reserves, victim user deposits, bridge treasury]
- **Direct Financial Impact:** [e.g., 100% loss of unlocked token liquidity without repayment]
- **Indirect Protocol Impact:** [e.g., Permanent desynchronization of price feeds, cascade liquidations]

---

## 6. Recommended Remediation

### 6.1 Architectural Solution
[Explanation of the recommended defense, architectural pattern (e.g., CEI, ReentrancyGuard, EIP-712).]

### 6.2 Concrete Code Diff
```diff
- // Vulnerable code
+ // Remediated code
```

---

## 7. Regression Validation & Invariant Testing

### 7.1 Regression Test Outcome
- **Test Command:** `forge test -vvv --match-contract <RegressionTest>`
- **Observed Result:** [Pass / Revert with expected custom error]

### 7.2 Invariant Verification
- **Invariants Tested:** [e.g., Constant-product K non-decreasing, reserves backing balances]
- **Handler Configuration:** [Number of runs, call depth, discard/revert metrics]

---

## 8. Known Limitations & Residual Risks

- [Document any edge cases, secondary trade-offs, gas overheads, or assumptions remaining outside the test suite.]
