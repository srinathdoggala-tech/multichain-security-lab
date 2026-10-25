# Adversarial Security Review: AMM Core, Router, TWAP Oracle & Non-Standard Tokens

---

## Provenance, Attribution & Audit Disclaimer

> **DISCLAIMER & NON-PRODUCTION NOTICE:**
> This security report is an independent, adversarial defensive security review authored for educational research and smart contract security auditor portfolio purposes.
> **This repository has NOT been commercially audited by an external third-party auditing firm and is NOT intended or warranted for production or mainnet deployment.**

### Material Classification & Provenance:
- **Inherited Material:** Base EVM educational challenge labs (reentrancy, oracle attack, signature replay) originated from [`void-node/My-first-smart-contract-audit-lab`](https://github.com/void-node/My-first-smart-contract-audit-lab).
- **Adapted Material:** The core constant-product AMM pair ([`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol)), slippage router ([`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol)), and TWAP oracle ([`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)) adapt canonical Uniswap v2 mechanisms to Solidity `0.8.28`, replacing legacy assembly/Solidity 0.6 constructs with OpenZeppelin `ReentrancyGuard`, custom errors, and modular math libraries.
- **Independently Authored Security Work:**
  1. Adversarial test suite [`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol) (13 tests covering boundary conditions, stale price exploitation, age aliasing across $2^{32}$ seconds, FoT socialization, rebase freezes, and rollover).
  2. Multi-tier staleness architecture in [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol):
     - Fail-closed default `consult(address token, uint256 amountIn)` enforcing `2 * period` maximum staleness.
     - Parameterized `consult(address token, uint256 amountIn, uint256 maxAge)` for protocol-specific freshness limits.
     - Explicitly separated `consultUnchecked(address token, uint256 amountIn)` with NatSpec warnings for off-chain indexing/analytics.
     - View helpers `observationAge()` and `isStale(maxAge)`.
  3. Perimeter zero-address validation in [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol) for `addLiquidity` and `removeLiquidity`.
  4. Stateful invariant harness upgrade [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol) implementing an operational idle bound (`MAX_HARNESS_IDLE_SECONDS = 30 days`), active `warpTime` progression (4,100+ warps across 50,000 calls), `invariant_PriceCumulativeModularProgress`, and bounded `invariant_TimestampConsistency`.

---

## Executive Summary

An independent, adversarial security review was performed on the `audit/adversarial-security-review` branch of `srinathdoggala-tech/multichain-security-lab`. The review verified core properties across the AMM pair, router, oracle, and adversarial token mocks.

- **Total Test Suites:** 31
- **Total Tests Passing:** 90 (0 failed, 0 skipped)
- **Stateful Invariant Testing:** 1,000 runs, 50,000 calls across all 6 invariants with active time warping and zero invariant violations.

---

## Findings & Classifications Matrix

Consistent status definitions applied across the review:
- `Confirmed`: Issue or property mathematically verified and validated via test proof-of-concept.
- `Remediated`: Root cause identified, fixed in source code, and verified by passing regression tests.
- `Partially Mitigated`: Risk significantly reduced by defensive guards, but residual risk or architectural limitation remains documented.
- `Design Limitation`: Inherent architectural constraint of the protocol model that cannot be altered without changing protocol scope.
- `Unverified`: Theoretical concern lacking an executable proof-of-concept or reproducible failure state.

| Finding ID | Title | Target File | Classification | Severity | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`AVIOR-ROUTER-001`** | Missing Perimeter Zero-Address Recipient Validation | [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol) | Input Validation Defect | **Low** | **Remediated** |
| **`AVIOR-ORACLE-001`** | Unbounded Observation Staleness in `consult()` | [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) | Integration Hazard / Design Limitation | **Medium** | **Partially Mitigated** |
| **`AVIOR-TEST-001`** | Invariant Test Harness Time Progression Blind Spot | [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol) | QA Deficiency / Test Coverage Blind Spot | **Medium** | **Remediated** |
| **`AVIOR-AMM-003`** | Asymmetric Fee-on-Transfer Liquidity Socialization | [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) | Protocol Compatibility Limitation | **Low / Info** | **Design Limitation** |
| **`AVIOR-AMM-004`** | Negative Elastic Rebase Pool Freezes Swaps Without `sync()` | [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) | Protocol Compatibility Limitation | **Low / Info** | **Design Limitation** |
| **`AVIOR-MATH-001`** | Quantitative Multi-Block TWAP Manipulation Cost | [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) | Economic Property Analysis | **Informational** | **Confirmed** |
| **`AVIOR-ORACLE-002`** | Cumulative Price Accumulator Modular Overflow | [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) | Arithmetic Property / Protocol Assumption | **Informational** | **Design Limitation** |

---

## Detailed Technical Findings

### 1. `AVIOR-ORACLE-001`: Observation Staleness & Modular Age Wrapping in `AviorTWAPOracle.sol`
* **Component:** [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Integration Hazard / Protocol Limitation
* **Severity:** **Medium** (CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:N — Score: 6.5)
* **Status:** **Partially Mitigated**
* **Technical Description:**
  In pull-based TWAP oracles, average prices are only refreshed when external keepers invoke `update()`. If keepers stall or market volatility spikes during an outage, an oracle consumer querying historical averages receives stale prices. In lending and collateral systems, reading stale prices allows attackers to borrow against depreciated collateral or evade liquidations.
* **Architecture & Interface Separation:**
  To prevent naive integrators from accidentally consuming stale prices while preserving functionality for off-chain view callers:
  1. **Fail-Closed Default Interface (`consult(token, amountIn)`):**
     Calls `consult(token, amountIn, period * 2)`. Reverts with `StalePrice(age, maxAge)` if the observation is older than 2 observation windows ($2 \times \text{period}$).
  2. **Parameterized Freshness Interface (`consult(token, amountIn, maxAge)`):**
     Enforces caller-defined freshness bounds:
     ```solidity
     function consult(address token, uint256 amountIn, uint256 maxAge) public view returns (uint256 amountOut) {
         uint32 age = observationAge();
         if (age > maxAge) revert StalePrice(age, maxAge);
         return consultUnchecked(token, amountIn);
     }
     ```
  3. **Explicitly Separated Unchecked Interface (`consultUnchecked(token, amountIn)`):**
     Clearly labeled as `Unchecked` with explicit NatSpec warnings. Retained strictly for off-chain indexing, analytics, and historical backtesting where timestamp filtering occurs off-chain.
* **The 136-Year `uint32` Modular Limitation:**
  `AviorTWAPOracle` records `blockTimestampLast` as `uint32` to match the AMM pair's storage slot packing.
  `observationAge()` calculates:
  $$\text{age} = \left(\text{uint32}(\text{block.timestamp}) - \text{blockTimestampLast}\right) \pmod{2^{32}}$$
  **Fundamental Protocol Assumption:** The oracle MUST receive an update at least once every $2^{32}-1$ seconds ($\approx 136.19$ years).
  **Behavior on Wrap:** If an oracle observation is neglected for $\Delta t \ge 2^{32}$ seconds, the elapsed time wraps modulo $2^{32}$. For example, if $2^{32} + 10$ seconds elapse, `observationAge()` computes 10 seconds. `isStale(3600)` returns `false` and `consult(..., 3600)` treats a 136-year-old observation as 10 seconds old.
* **Residual Risks:**
  1. Calling `consultUnchecked` bypasses all freshness validation. Any on-chain DeFi protocol integrating `consultUnchecked` is exposed to stale-price arbitrage.
  2. Freshness enforcement cannot detect observation dormancy exceeding $2^{32}$ seconds (~136.19 years) due to `uint32` timestamp aliasing.
* **Regression Tests ([`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol)):**
  - `test_Adversarial_StaleObservationReturnedWhenUpdateNeglected`: Proves that 30-day stale data causes `consult(token, amount)` to revert with `StalePrice(30 days, 2 * period)`, `consult(token, amount, 1 days)` to revert with `StalePrice(30 days, 1 days)`, while `consultUnchecked` returns the stale price.
  - `test_Adversarial_DualInterfaceStaleEnforcement`: Proves all 3 entry points return identical values when fresh, and fail-closed methods revert when age exceeds limits.
  - `test_Adversarial_ObservationAgeWrapsAfter136Years`: Proves that warping $2^{32} + 10$ seconds wraps `observationAge()` to 10 seconds, demonstrating the modular aliasing limit.
  - `test_Adversarial_UninitializedOracleRevertsOnConsult`: Proves uninitialized oracles revert on all entry points with `OracleNotInitialized()`.

---

### 2. `AVIOR-TEST-001`: Invariant Test Harness Time Progression & Modular Properties
* **Component:** [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol)
* **Classification:** QA Deficiency / Test Coverage Blind Spot
* **Severity:** **Medium**
* **Status:** **Remediated**
* **Technical Description:**
  The initial invariant fuzzing harness executed 50,000 actions without ever advancing EVM block time. Consequently, `timeElapsed` in the pair's `_update` remained 0, leaving cumulative price accumulators unexercised.
  Furthermore, the previous invariant `invariant_PriceCumulativeMonotonic` asserted unconditional monotonicity (`assertGe(p0, lastP0)`). Because cumulative price accumulators are 256-bit unsigned integers that wrap modulo $2^{256}$, unconditional monotonicity is mathematically invalid in an unbounded domain.
* **Remediation Implemented:**
  1. **Bounded Operational Idle Model:**
     Added `MAX_HARNESS_IDLE_SECONDS = 30 days` to `AMMHandler`. All state-mutating pair actions (`swap0`, `swap1`, `addLiquidity`, `removeLiquidity`, `skim`, `sync`, `swapViaRouter`) record `lastPairActionTimestamp = block.timestamp;`.
  2. **Active Time Warping:**
     `warpTime(uint256 timeSeed)` advances time dynamically between 1 second and 1 day, while bounding cumulative idle time within `MAX_HARNESS_IDLE_SECONDS`.
  3. **Verified Timestamp Consistency:**
     Because idle time between interactions is strictly bounded to 30 days ($2,592,000\text{s} \ll 2^{31}$), the signed two's complement half-circle property `elapsed < 2^31` is guaranteed to hold for **every sequence permitted by the harness**, rather than relying on random fuzz distribution.
  4. **Modular Cumulative Progress Property:**
     Replaced unconditional monotonicity with `invariant_PriceCumulativeModularProgress`. Documented the non-wrapping domain assumption (accumulators start at 0 and do not exceed $2^{256}$ within 50,000 steps). Direct modular overflow across $2^{256}$ and $2^{32}$ rollover is independently verified via deterministic unit tests in `AdversarialSecurityAudit.t.sol`.
* **Verification:**
  1,000 runs, 50,000 calls. `warpTime` was invoked **4,112 times** with 0 invariant violations across all 6 invariants.

---

### 3. `AVIOR-ROUTER-001`: Missing Perimeter Zero-Address Recipient Validation
* **Component:** [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol)
* **Classification:** Input Validation Defect
* **Severity:** **Low**
* **Status:** **Remediated**
* **Technical Description:**
  While `AviorRouter.swapExactTokensForTokens` contained `if (to == address(0)) revert ZeroAddress();`, `addLiquidity` and `removeLiquidity` lacked perimeter validation for recipient addresses.
* **Remediation Implemented:**
  Added explicit zero-address perimeter checks:
  ```solidity
  if (to == address(0)) revert ZeroAddress();
  ```
  to both [`addLiquidity`](../src/dex/AviorRouter.sol#L192) and [`removeLiquidity`](../src/dex/AviorRouter.sol#L209).
* **Regression Test:**
  Verified in `test_Adversarial_RouterZeroRecipientHandling`: attempts to call `addLiquidity` or `removeLiquidity` with `to == address(0)` revert with `AviorRouter.ZeroAddress.selector`.

---

### 4. `AVIOR-AMM-003`: Fee-on-Transfer Liquidity Socialization & Stakeholder Accounting
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) / [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol)
* **Classification:** Protocol Compatibility Limitation
* **Severity:** **Low / Informational**
* **Status:** **Design Limitation**
* **Rigorous Mathematical Breakdown & Stakeholder Balances:**
  1. **Initial Genesis State:**
     Alice deposits 2,000 FoT (5% transfer tax) and 1,900 STD (standard token).
     - Tax recipient collects: $2000 \times 0.05 = 100\text{ FoT}$.
     - Pair receives: $1900\text{ FoT}$, $1900\text{ STD}$.
     - Minted shares: $\sqrt{1900 \times 10^{18} \cdot 1900 \times 10^{18}} = 1900 \times 10^{18}$ LP shares.
     - `MINIMUM_LIQUIDITY` permanently locked to `DEAD_ADDRESS` (`0xdead`): $1000\text{ wei}$ ($10^{-15}$ ether).
     - Alice receives: $1900 \times 10^{18} - 1000\text{ wei}$ shares.
     - Total supply: $1900 \times 10^{18}$ shares. Reserves: $R_0 = 1900$, $R_1 = 1900$.
  2. **Bob Adds Liquidity:**
     Bob deposits 100 FoT and 100 STD via `AviorRouter.addLiquidity`.
     - 5% tax deducted on FoT transfer: 5 FoT to `TAX_RECIPIENT`, pair receives **95 FoT**.
     - STD token incurs no fee: pair receives **100 STD**.
     - Minted shares calculated on minimum asset ratio:
       $$\text{liquidity} = \min\left(\frac{95 \cdot 10^{18} \times 1900 \cdot 10^{18}}{1900 \cdot 10^{18}}, \frac{100 \cdot 10^{18} \times 1900 \cdot 10^{18}}{1900 \cdot 10^{18}}\right) = \mathbf{95 \times 10^{18}\text{ LP shares}}$$
     - Post-deposit total supply: $1995 \times 10^{18}$ LP shares.
     - Post-deposit pool reserves: $1995\text{ FoT}$, $2000\text{ STD}$.
     - Bob receives 95 LP shares. The uncredited 5 STD tokens remain in the pool.
  3. **Bob Burns Liquidity:**
     Bob burns his 95 LP shares via `AviorRouter.removeLiquidity`:
     - FoT share: $\frac{95 \cdot 10^{18} \times 1995 \cdot 10^{18}}{1995 \cdot 10^{18}} = 95\text{ FoT}$.
       Transferring from pair to Bob incurs a second 5% exit tax:
       $95 \times 0.05 = 4.75\text{ FoT}$ to `TAX_RECIPIENT`.
       Bob receives: $95 - 4.75 = \mathbf{90.25\text{ FoT}}$.
     - STD share:
       $$\text{amountSTD} = \frac{95 \cdot 10^{18} \times 2000 \cdot 10^{18}}{1995 \cdot 10^{18}} = \frac{2000}{21} \cdot 10^{18} \approx \mathbf{95.238095238... \times 10^{18}\text{ STD}}$$
  4. **Stakeholder Net Balance Changes:**
     - **Bob:** Deposited 100 STD, received $\frac{2000}{21} \approx 95.238$ STD. Permanent loss = $\frac{100}{21} \approx \mathbf{4.761905\text{ STD tokens}}$.
       Deposited 100 FoT, received 90.25 FoT. Loss = $9.75\text{ FoT}$ (paid to `TAX_RECIPIENT`).
     - **TAX_RECIPIENT:** Collected $5.0 + 4.75 = \mathbf{9.75\text{ FoT}}$.
     - **Pool Reserves After Bob's Exit:** $1900\text{ FoT}$, $\frac{40000}{21} \approx 1904.761905\text{ STD}$. Total supply: $1900 \times 10^{18}$ LP shares.
     - **Alice:** Holds $\frac{1900 \cdot 10^{18} - 1000}{1900 \cdot 10^{18}}$ of remaining LP supply ($99.999999999999947\%$).
       Alice's claim on pool STD increased from 1,900 STD to $1904.761904\text{ STD}$ ($+\mathbf{4.761904\text{ STD}}$).
     - **DEAD_ADDRESS (`0xdead`):** Holds $1000\text{ wei}$ of LP supply.
       Permanently locked minimum liquidity increased by $+2506\text{ wei STD}$.
  5. **Router Swaps:**
     In `test_Adversarial_RouterRejectsFeeOnTransferSwap`, swapping FoT tokens through the router reverts with `AviorAMMPairSecured.InvalidK.selector` because the fee deficit violates the constant-product check.
* **Conclusion:** `AviorRouter` does not support Fee-on-Transfer tokens. Dedicated supporting routers (`swapExactTokensForTokensSupportingFeeOnTransferTokens`) are required.

---

### 5. `AVIOR-AMM-004`: Negative Elastic Rebase Freezes Pool Swaps Without `sync()`
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol)
* **Classification:** Protocol Compatibility Limitation
* **Severity:** **Low / Informational**
* **Status:** **Design Limitation**
* **Mechanism & Verification:**
  When a rebasing token contracts its supply, physical contract balance drops below stored `reserve`. Any subsequent swap evaluating `(balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000^2)` reverts with `InvalidK()` because of the unaccounted deficit. Swaps remain frozen until `pair.sync()` is executed. Verified in `test_Adversarial_NegativeRebaseBricksSwapsWithoutSync`.

---

### 6. `AVIOR-MATH-001`: Quantitative Multi-Block TWAP Manipulation Cost
* **Component:** [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Economic Property Analysis
* **Severity:** **Informational**
* **Status:** **Confirmed**
* **Mathematical Derivation & Empirical Verification:**
  $$\text{TWAP} = \frac{1}{T} \int_{0}^{T} P(t) \, dt$$
  - In a single block manipulation ($t_{\text{manip}} = 12\text{s}$, $T = 1800\text{s}$), a $100\times$ spot price drop ($P \approx 0.01$) produces a theoretical duration-weighted impact of $\frac{12}{1800} \times 0.99 \approx 0.66\%$.
  - When the attacker unwinds the position at $t=12\text{s}$, 0.3% pool swap fees are retained on both legs, shifting post-reversion baseline spot price by $\approx 0.49\%$ for the remaining $1,788\text{s}$.
  - Total empirical TWAP quote shift: **1.142%** (verified in `test_Adversarial_SustainedPriceManipulationHoldingCost`).
  - Single-block flash manipulation is dampened by $\sim 98.86\%$. Shifting the average by $>80\%$ requires sustaining the imbalance across all 150 blocks, exposing the attacker to massive external arbitrage losses.

---

### 7. `AVIOR-ORACLE-002`: Cumulative Price Accumulator Modular Overflow & Rollover
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) / [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Arithmetic Property / Protocol Assumption
* **Severity:** **Informational**
* **Status:** **Design Limitation**
* **Verified Scenarios ([`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol)):**
  1. **Timestamp Rollover Across $2^{32}-1$:**
     `test_Adversarial_TimestampRolloverAcrossUint32Max` warps from $2^{32}-100$ to $1800$ (elapsed = 1900s). Unsigned modular subtraction $1800 - (2^{32}-100) = 1900$ correctly computes elapsed time without overflow.
  2. **Interim Reserve Shifts Across Rollover:**
     `test_Adversarial_RolloverWithInterimReserveChanges` executes a reserve-shifting swap 50s before rollover, warps across $2^{32}-1$ to $t = 1750$ (total elapsed = 1850s), and confirms the oracle computes the exact piece-wise average ($\approx 27\text{ ether}$).
  3. **Zero Elapsed Time:**
     `test_Adversarial_ZeroElapsedTimeInOracleAndPair` confirms back-to-back swaps in the same block ($timeElapsed == 0$) do not advance cumulative accumulators, and calling `oracle.update()` in the same block reverts with `PeriodNotElapsed(0, period)`.
  4. **Uninitialized Oracle Access:**
     `test_Adversarial_UninitializedOracleRevertsOnConsult` confirms calling `consult`, `consult(..., maxAge)`, or `consultUnchecked` prior to any update reverts with `OracleNotInitialized()`.
  5. **136-Year Modular Age Aliasing:**
     `test_Adversarial_ObservationAgeWrapsAfter136Years` proves that if an observation interval reaches $2^{32} + 10$ seconds (~136.19 years), `observationAge()` wraps to 10 seconds, misclassifying the observation as fresh.
  6. **Cumulative Modular Subtraction Across $2^{256}$:**
     Two's complement subtraction `unchecked { price0Cumulative - price0CumulativeLast }` accurately computes positive price growth even when the accumulator wraps across $2^{256}-1$.

---

## Static Analysis & Compiler Diagnostics

Foundry AST compiler analysis (`forge build`) was executed on all contracts:
- `warning[reentrancy-no-eth]`: External calls to `IAviorCallee.aviorCall(...)` in `AviorAMMPairSecured.sol`. Verified guarded by OpenZeppelin `ReentrancyGuard` (`nonReentrant`), proven by 4,185 callback reentrancy attempts in invariant testing.
- `warning[unsafe-typecast]`: Downcasting balances to `uint112`. Verified guarded by explicit overflow reverts (`if (balance0 > type(uint112).max) revert Overflow()`).

---

## Unresolved Risks & Operational Recommendations

1. **Pull-Based TWAP Keeper Dependency & `consultUnchecked` Hazard:**
   `AviorTWAPOracle` requires regular updates. On-chain protocols MUST use `consult(token, amountIn, maxAge)` or the fail-closed default `consult(token, amountIn)` with an explicit staleness limit. Under no circumstances should lending or liquidation mechanisms invoke `consultUnchecked`.
2. **136-Year Timestamp Wrap Assumption:**
   `AviorTWAPOracle` relies on `uint32` modular arithmetic matching `pair.blockTimestampLast`. Automated keepers must invoke `update()` at least once per 136-year epoch to prevent age wrap-around aliasing.
3. **Lack of Native Fee-on-Transfer Support in Router:**
   `AviorRouter.sol` does not support Fee-on-Transfer tokens. Deploying pairs with taxed tokens requires specialized wrapper routers.
4. **Rebase Sync Automation:**
   Negative rebases freeze pool swaps with `InvalidK` until `pair.sync()` is executed. Automated keepers must monitor rebase events.
5. **Single-Validator Bridge Key:**
   `CrossChainMessageVaultSecured` uses a single validator key. Production bridges require decentralized threshold signature schemes (TSS) or multi-validator quorums.
6. **Educational Lab Notice:**
   This project is an educational security research lab and portfolio demonstration. It has not undergone formal commercial audit by an external security firm and is not warranted for mainnet deployment.
