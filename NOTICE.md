# Provenance & Attribution Notice

## Project Identity & Provenance
This project, evolved as **DeFiSentinel — DEX & Cross-Chain Security Research Lab**, builds upon the foundation of:
- **Upstream Repository:** [https://github.com/void-node/My-first-smart-contract-audit-lab](https://github.com/void-node/My-first-smart-contract-audit-lab)
- **Original Author:** [void-node](https://github.com/void-node)
- **Original License:** MIT License

In accordance with open-source ethical research principles and the MIT license, original copyright and attribution are fully acknowledged and retained. No Git history has been fabricated or erased.

---

## Code Attribution Breakdown

### 1. Inherited Upstream Code
The following files and prototypes were inherited from the upstream repository:
- `src/Bank.sol`, `src/Attacker.sol`, `test/Exploit.t.sol` (Lab 01: Reentrancy)
- `src/DeFiPool.sol`, `src/Lending.sol`, `src/LendingPlatform.sol`, `src/Oracle.sol`, `test/OracleAttack.t.sol` (Lab 02: Price Manipulation)
- `src/SimpleVault.sol`, `test/SimpleVaultAttack.t.sol` (Lab 04: Unchecked Call)
- `src/FlashPool.sol`, `src/FlashLoanPool.sol`, `src/VulnerableVault.sol`, `test/FlashAttack.t.sol`, `reports/Lab5-FlashLoan-Report.md` (Lab 05: Flash Loan Reward)
- `src/TimeVault.sol`, `test/TimeVault.t.sol` (Lab 07/08: Timestamp Dependency)
- `src/Governance.sol`, `src/GovernanceToken.sol`, `test/GovernanceTest.t.sol` (Lab 09: Governance Flash Attack)
- `src/StakingPool.sol`, `test/StakingPoolTest.t.sol` (Lab 10: Staking Calculation)
- `src/CreamMarket.sol`, `src/CreamAttack.sol`, `test/CreamMarketTest.t.sol` (Lab 11: Callback Reentrancy)
- `src/LendfMe.sol`, `src/LendfMeAttack.sol`, `test/LendfMeTest.t.sol` (Lab 12: ERC-777 Hook Reentrancy)
- `src/InflatableVault.sol`, `test/InflatableVault.t.sol` (Lab 13: Vault Inflation)
- `src/UniV3OracleLending.sol`, `test/UniV3OracleManipulationTest.t.sol` (Lab 14: TWAP Oracle Mock)
- `src/ReadOnlyAttack.sol`, `test/ReadOnlyTest.t.sol`, `src/VulnerableShares.sol`, `test/VulnerableSharesTest.t.sol` (Lab 15: Read-Only Reentrancy & Fuzzing)
- `src/ArbitrageVault.sol`, `test/ArbitrageTest.t.sol` (Lab 16: Arbitrage)
- `src/SignatureVault.sol`, `src/SignatureReplayVault.sol`, `test/SignatureAttack.t.sol`, `test/SignatureReplayVault.t.sol` (Lab 17: Signature Replay)
- `src/BridgeProofVault.sol`, `test/BridgeProofVault.t.sol` (Lab 18: Bridge Merkle Verification)
- `src/CrossChainMessageVault.sol`, `test/CrossChainMessageVault.t.sol` (Lab 19: Cross-Chain Message Replay Flaw)
- `src/AccountingDriftVault.sol`, `src/AccountingDriftVaultFixed.sol`, `test/AccountingDriftVault.t.sol` (Lab 20: Accounting Drift & Invariants)

---

### 2. Newly Authored Original Research & Engineering
The following modules, tests, invariant suites, and audit reports were authored independently for this project:

#### A. DEX & AMM Core Security Lab (`src/dex/`, `test/dex/`, `test/invariants/`)
- `src/dex/IAviorCallee.sol`: Flash swap callback interface.
- `src/dex/AviorAMMPair.sol`: Educational AMM core demonstrating flash swap callback reentrancy and flawed fee-omitting K checks.
- `src/dex/AviorAMMPairSecured.sol`: Remediated AMM pair implementing OpenZeppelin `ReentrancyGuard`, strict 0.3% fee-adjusted K-invariant (`(1000*b0 - 3*in0)*(1000*b1 - 3*in1) >= 1000^2*r0*r1`), and genesis `MINIMUM_LIQUIDITY` (1000) dead lock.
- `test/mocks/MockERC20.sol`: Test helper mock token.
- `test/dex/AviorAMMPairExploit.t.sol`: Reproducible proof of concept for callback reentrancy draining reserves and genesis share inflation.
- `test/regressions/AviorAMMPairRegression.t.sol`: Regression test verifying reentrancy blocking, fee enforcement, and K-invariant property fuzzing.
- `test/invariants/AviorAMMPairInvariant.t.sol`: Stateful invariant test using Foundry `AMMHandler` asserting K-growth, reserve backing, and dead-address lock across 1,000 runs and 50,000 calls.

#### B. Cross-Chain Security Hardening (`src/crosschain/`, `test/regressions/`)
- `src/crosschain/CrossChainMessageVaultSecured.sol`: Remediated bridge endpoint using EIP-712 typed structured data, explicit `block.chainid` destination validation, contract address binding, and per-user monotonic nonces.
- `test/regressions/CrossChainMessageVaultRegression.t.sol`: Regression test proving cross-chain replay across Chain 1 (Ethereum) and Chain 56 (BSC) is unconditionally rejected.

#### C. Formal Security Audit Reports (`reports/`, `docs/`)
- `docs/INITIAL_ASSESSMENT.md`: Rigorous pre-development assessment of repository toolchain, discrepancies, and baselines.
- `reports/REPORT_TEMPLATE.md`: Standardized professional security reporting framework.
- `reports/REPORT_DEX_01_AMM_REENTRANCY_RESERVE_DESYNC.md`: Comprehensive CVSS 9.8 report for flash swap reentrancy.
- `reports/REPORT_CC_01_CROSS_CHAIN_MESSAGE_REPLAY.md`: Comprehensive CVSS 10.0 report for cross-chain validator replay.
- `reports/REPORT_VAULT_01_ACCOUNTING_DRIFT.md`: Comprehensive CVSS 8.1 report for share-vault write-before-read drift.
- Modernized and verified CI configuration in `.github/workflows/test.yml`.
