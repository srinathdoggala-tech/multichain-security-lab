# Audit Report: Lab 5 - Flash Loan Vulnerability

## 1. Executive Summary
**Severity:** High  
**Status:** Exploited & Documented  
**Vulnerability:** Business Logic Flaw in Reward Calculation.

## 2. Vulnerability Description
The `VulnerableVault` contract calculates rewards based on the instantaneous balance of the `FlashPool`. An attacker can manipulate this by taking a massive flash loan, artificially inflating the reward conditions within a single transaction.

## 3. The Exploit
1. Attacker borrows 100 ETH via Flash Loan.
2. In the same transaction, the attacker calls `claimReward()`.
3. The Vault sees the massive balance and grants the reward.
4. Attacker repays the Flash Loan.
**Result:** Attacker gains rewards for "free".

## 4. Remediation
To prevent this attack, the protocol should use **Historical Balances (Snapshots)** or require a **Time-lock** (e.g., rewards can only be claimed if funds were held for at least 1 block).
