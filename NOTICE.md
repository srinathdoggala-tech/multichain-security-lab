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
### 2. Adapted Demonstrations (Labs 19-20)
The following modules were adapted from canonical DeFi vulnerability patterns (cross-chain replay, vault drift) and expanded with concrete exploit test cases:
- `src/CrossChainMessageVault.sol`, `test/CrossChainMessageVault.t.sol` (Demonstrating missing chain/nonce tracking)
- `src/AccountingDriftVault.sol`, `src/AccountingDriftVaultFixed.sol`, `test/AccountingDriftVault.t.sol` (Demonstrating share-to-asset balance drift and 100% solvency restoration)

---

### 3. Newly Authored Original Research, Architecture & Advanced Security Labs
The following modules, invariant suites, adversarial test suites, oracles, and audit reports were authored independently for this project:

#### A. DEX & AMM Core Security Lab (`src/dex/`, `test/dex/`, `test/invariants/`)
- `src/dex/IAviorCallee.sol`: Flash swap callback interface.
- `src/dex/AviorAMMPair.sol`: Educational AMM core demonstrating flash swap callback reentrancy and flawed fee-omitting K checks.
- `src/dex/AviorAMMPairSecured.sol`: Remediated AMM pair implementing OpenZeppelin `ReentrancyGuard`, isolated `_validateK` pure helper preventing stack-too-deep, strict 0.3% fee-adjusted K-invariant, cumulative price accumulators (`price0CumulativeLast`, `price1CumulativeLast`), and genesis `MINIMUM_LIQUIDITY` (1000) dead lock.
- `src/dex/libraries/UQ112x112.sol`: Binary fixed-point math library for AMM time-weighted cumulative prices.
- `src/dex/AviorTWAPOracle.sol`: Time-Weighted Average Price (TWAP) oracle module providing manipulation resistance against single-block flash loan exploits via price accumulators, time-delta snapshots, and spot divergence consultation.
- `src/dex/AviorRouter.sol`: Educational multi-hop AMM router supporting exact-input swaps, `amountOutMin` slippage enforcement, deadline validation, pair registry, optimal liquidity provisioning (`addLiquidity`), liquidity burning (`removeLiquidity`), and SafeERC20 asset transfers.
- `test/mocks/MockERC20.sol`: Standard ERC-20 test helper mock token.
- `test/dex/AviorAMMPairExploit.t.sol`: Reproducible proof of concept for callback reentrancy draining reserves and genesis share inflation.
- `test/dex/AviorRouter.t.sol`: Unit test verifying single-hop, multi-hop routing (`tokenA -> tokenB -> tokenC`), optimal liquidity addition, and liquidity burning.
- `test/dex/AviorTWAPOracle.t.sol`: Unit and regression test suite verifying TWAP window enforcement, mathematical convergence, single-block flash-loan manipulation immunity, and invalid token protection.
- `test/regressions/AviorAMMPairRegression.t.sol`: Regression test verifying reentrancy blocking, fee enforcement, and K-invariant property fuzzing.
- `test/regressions/AviorRouterRegression.t.sol`: Comprehensive regression and adversarial test suite for router slippage violations, expired deadlines, invalid paths, and 1 wei dust rounding edge cases.
- `test/invariants/AviorAMMPairInvariant.t.sol`: Stateful invariant test using Foundry `AMMHandler` asserting K-growth, reserve backing, dead-address lock, and zero-share burn protection across 1,000 runs and 50,000 calls.

#### B. Adversarial ERC-20 Token Behavior Research (`test/mocks/`, `test/dex/`)
- `test/mocks/FeeOnTransferToken.sol`: Deflationary token deducting 5% on transfers, demonstrating AMM balance-delta vs router naive expectation desync.
- `test/mocks/RebasingToken.sol`: Elastic-supply token demonstrating that positive rebases allow arbitrageurs to extract unearned LP yield via `skim()`, while negative rebases force reserve drops on `sync()`.
- `test/mocks/MissingReturnToken.sol`: Non-standard USDT/BNB-style token omitting boolean returns, validating `SafeERC20` necessity.
- `test/mocks/ReentrantHookToken.sol`: ERC-777/ERC-1363 callback token demonstrating that non-reentrant guards prevent transfer-hook reentrancy into AMM pools and routers.
- `test/dex/AdversarialTokens.t.sol`: End-to-end test suite confirming pool and router behavior against all 4 adversarial token models.

#### C. Cross-Chain Security Hardening (`src/crosschain/`, `test/regressions/`)
- `src/crosschain/CrossChainMessageVaultSecured.sol`: Remediated bridge endpoint using EIP-712 typed structured data, explicit `block.chainid` destination validation, contract address binding, and per-user monotonic nonces.
- `test/regressions/CrossChainMessageVaultRegression.t.sol`: Regression test proving cross-chain replay across Chain 1 (Ethereum) and Chain 56 (BSC), cross-contract replay, payload tampering, unauthorized signers, and malformed signatures are unconditionally rejected.

#### D. Formal Security Audit Reports & Architecture Docs (`reports/`, `docs/`)
- `docs/INITIAL_ASSESSMENT.md`: Rigorous pre-development assessment of repository toolchain, discrepancies, and baselines.
- `docs/SECOND_PHASE_REVIEW.md`: Independent audit of the implemented system, compilation, and security findings.
- `docs/AMM_SECURITY_REVIEW.md`: Line-by-line AMM re-audit, invariant derivations, and residual risk analysis.
- `docs/INVARIANTS.md`: Formal specification of AMM & DEX stateful invariants, handler action space, and verification logs.
- `docs/CROSS_CHAIN_THREAT_MODEL.md`: Deep threat model covering STRIDE, EIP-712 domain separation, single-validator trust assumptions, and finality risks.
- `reports/REPORT_TEMPLATE.md`: Standardized professional security reporting framework.
- `reports/REPORT_DEX_01_AMM_REENTRANCY_RESERVE_DESYNC.md`: Comprehensive CVSS 9.8 report for flash swap reentrancy.
- `reports/REPORT_CC_01_CROSS_CHAIN_MESSAGE_REPLAY.md`: Comprehensive CVSS 10.0 report for cross-chain validator replay.
- `reports/REPORT_VAULT_01_ACCOUNTING_DRIFT.md`: Comprehensive CVSS 8.1 report for share-vault write-before-read drift.
- Modernized and verified CI configuration in `.github/workflows/test.yml`.
