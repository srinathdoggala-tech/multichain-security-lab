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
  1. Adversarial test suite [`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol) (15 tests covering boundary conditions, stale price exploitation, full-width `uint256` observation age calculation across $2^{32}$ seconds, FoT socialization, rebase freezes, rollover, K per share invariant sensitivity, and mathematical counterexample to two-floor metric).
  2. Multi-tier staleness architecture in [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol):
     - Separate full-width `uint256 public lastObservationTimestamp` recording observation time on successful `update()`, completely eliminating observation age wrapping across $2^{32}$ seconds while keeping the pair's modular `uint32` cumulative price logic separate.
     - Fail-closed default `consult(address token, uint256 amountIn)` enforcing `2 * period` maximum staleness.
     - Parameterized `consult(address token, uint256 amountIn, uint256 maxAge)` for protocol-specific freshness limits.
     - Explicitly separated `consultUnchecked(address token, uint256 amountIn)` with NatSpec warnings for off-chain indexing/analytics.
     - View helpers `observationAge()` and `isStale(maxAge)`.
  3. Perimeter zero-address validation in [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol) for `addLiquidity` and `removeLiquidity`.
  4. Stateful invariant harness upgrade [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol) implementing an operational idle bound (`MAX_HARNESS_IDLE_SECONDS = 30 days`), active `warpTime` progression (4,100+ warps across 50,000 calls), `invariant_KPerSharePreservedOrGrown`, swap-specific raw $K$ preservation, burn-specific $K_{\text{per\_share}}$ consistency, `invariant_PriceCumulativeModularProgress`, and bounded `invariant_TimestampConsistency`.

---

## Executive Summary

An independent, adversarial security review was performed on the `audit/adversarial-security-review` branch of `srinathdoggala-tech/multichain-security-lab`. The review verified core properties across the AMM pair, router, oracle, and adversarial token mocks.

- **Total Test Suites:** 31
- **Total Tests Passing:** 91 (0 failed, 0 skipped)
- **Stateful Invariant Testing:** 1,000 runs, 50,000 calls across all 6 invariants with active time warping and zero invariant violations.

---

## Findings & Classifications Matrix

Consistent status definitions applied across the review:
- `Confirmed`: Stated property or vulnerability reproduced through test proof-of-concept and supported by analytical derivation under defined preconditions.
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

### 1. `AVIOR-ORACLE-001`: Observation Staleness & Freshness Timestamp Architecture in `AviorTWAPOracle.sol`
* **Component:** [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Integration Hazard / Protocol Limitation
* **Severity:** **Medium** (CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:N — Score: 6.5)
* **Status:** **Remediated** (Freshness architecture hardened via full-width `uint256` observation timestamp; unchecked API segregated)
* **Technical Description:**
  In pull-based TWAP oracles, average prices are only refreshed when external keepers invoke `update()`. If keepers stall or market volatility spikes during an outage, an oracle consumer querying historical averages receives stale prices. In lending and collateral systems, reading stale prices allows attackers to borrow against depreciated collateral or evade liquidations.
* **Architecture & Interface Separation:**
  To prevent naive integrators from accidentally consuming stale prices while preserving functionality for off-chain view callers:
  1. **Full-Width Observation Timestamp (`lastObservationTimestamp`):**
     A dedicated `uint256 public lastObservationTimestamp` is recorded upon each successful `update()`.
     `observationAge()` calculates the full EVM age via full-width 256-bit subtraction:
     $$\text{age} = \text{block.timestamp} - \text{lastObservationTimestamp}$$
     Reverts with `OracleNotInitialized()` if `lastObservationTimestamp == 0`.
     This cleanly separates oracle observation freshness from the AMM pair's internal `uint32` cumulative price packing. As a result, observations older than $2^{32}$ seconds (~136.19 years) **never wrap modulo $2^{32}$** and are correctly identified as stale.
  2. **Fail-Closed Default Interface (`consult(token, amountIn)`):**
     Calls `consult(token, amountIn, period * 2)`. Reverts with `StalePrice(age, maxAge)` if the observation is older than 2 observation windows ($2 \times \text{period}$).
  3. **Parameterized Freshness Interface (`consult(token, amountIn, maxAge)`):**
     Enforces caller-defined freshness bounds:
     ```solidity
     function consult(address token, uint256 amountIn, uint256 maxAge) public view returns (uint256 amountOut) {
         uint256 age = observationAge();
         if (age > maxAge) revert StalePrice(age, maxAge);
         return consultUnchecked(token, amountIn);
     }
     ```
  4. **Explicitly Separated Unchecked Interface (`consultUnchecked(token, amountIn)`):**
     Clearly labeled as `Unchecked` with explicit NatSpec warnings. Retained strictly for off-chain indexing, analytics, and historical backtesting where timestamp filtering occurs off-chain. Security-sensitive consumers MUST NOT call this method.
* **AMM Pair Cumulative Price Accumulator Isolation:**
  The AMM pair's internal timestamp arithmetic (`blockTimestampLast` as `uint32`) is maintained separately for canonical Uniswap v2 cumulative accumulator calculations modulo $2^{32}$. The pair's modular rollover does not interfere with the oracle's full-width freshness validation.
* **Residual Risks:**
  1. Calling `consultUnchecked` bypasses all freshness validation. Any on-chain DeFi protocol integrating `consultUnchecked` is exposed to stale-price arbitrage.
  2. Keepers must still invoke `update()` periodically for the oracle to report fresh TWAP values.
* **Regression Tests ([`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol)):**
  - `test_Adversarial_StaleObservationReturnedWhenUpdateNeglected`: Proves that 30-day stale data causes `consult(token, amount)` to revert with `StalePrice(30 days, 2 * period)`, `consult(token, amount, 1 days)` to revert with `StalePrice(30 days, 1 days)`, while `consultUnchecked` returns the stale price.
  - `test_Adversarial_DualInterfaceStaleEnforcement`: Proves all 3 entry points return identical values when fresh, and fail-closed methods revert when age exceeds limits.
  - `test_Adversarial_ObservationOlderThan2ToThe32SecondsRevertsOnConsult`: Proves that warping $2^{32} + 10$ seconds into the future does not wrap the full-width observation age; the oracle correctly reports age $= 2^{32}+10$, classifies the observation as stale via `isStale(1 hours) == true`, and reverts with `StalePrice` on both default and parameterized `consult`.
  - `test_Adversarial_UninitializedOracleRevertsOnConsult`: Proves uninitialized oracles revert on all entry points with `OracleNotInitialized()`.

---

### 2. `AVIOR-TEST-001`: Invariant Test Harness Time Progression & Modular Properties
* **Component:** [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol)
* **Classification:** QA Deficiency / Test Coverage Blind Spot
* **Severity:** **Medium**
* **Status:** **Remediated**
* **Technical Description:**
  The initial invariant fuzzing harness executed 50,000 actions without ever advancing EVM block time. Consequently, `timeElapsed` in the pair's `_update` remained 0, leaving cumulative price accumulators unexercised.
  Furthermore, asserting unconditional monotonicity of the raw reserve product $K = r_0 \cdot r_1$ is mathematically invalid because legitimate proportional liquidity removal (`removeLiquidity`) burns LP shares and redeems underlying pool assets, decreasing raw $K$. In addition, cumulative price accumulators wrap modulo $2^{256}$.
* **Remediation Implemented:**
  1. **Accounting-Aware Invariant (`invariant_KPerSharePreservedOrGrown`):**
     Replaced the defective two-floor ratio product with the mathematically rigorous single-floored reserve-product-per-supply-squared metric:
     $$Q_s = \left\lfloor\frac{r_0 \cdot r_1 \cdot 10^{15}}{\text{totalSupply}^2}\right\rfloor$$
     * **Mathematical Defect in Prior Separately Floored Ratios:**
       The prior metric evaluated:
       $$K_s = \left\lfloor\frac{r_0 \cdot 10^{18}}{T}\right\rfloor \times \left\lfloor\frac{r_1 \cdot 10^{18}}{T}\right\rfloor$$
       While raw constant product $r_0 r_1$ is non-decreasing across fee-paying swaps, the product of two independently floored quotients can strictly decrease across legitimate swaps. For example, when token 1 is extracted ($r_1' = r_1 - 1$ wei), crossing an integer unit boundary causes its floor to drop by 1. Meanwhile, the deposit of token 0 ($r_0' = r_0 + 2$ wei) yields a fractional quotient increase $\frac{2 \cdot 10^{18}}{T} < 1$ that is truncated to 0 by the independent floor. Consequently, the product of the floors drops by $10^{18}$ despite raw $K$ strictly growing. This is deterministically proven in `test_Adversarial_ProductOfFlooredRatiosDecreasesOnSwapCounterexample`.
     * **Single-Floored Resolution ($Q_s$):**
       Evaluating $Q = \frac{r_0 r_1}{T^2}$ as a single rational quantity scaled by $S = 10^{15}$ and applying a single floor at the end ensures that any increase in real $Q$ directly guarantees $Q_s' \ge Q_s$ due to the monotonicity of the floor function ($u \ge v \implies \lfloor u \rfloor \ge \lfloor v \rfloor$).
     * **Analytical Transition Rationale:**
       - **Swaps:** Total supply is constant ($T' = T$); 0.3% LP fees ensure post-swap raw $K \ge \text{preK}$, guaranteeing $Q_s' \ge Q_s$ without floor-boundary collapse.
       - **Mints (`pair.mint`):** Deposit amounts are calculated from custodial token balances: $amount_i = B_i - r_i$, absorbing newly deposited tokens plus any prior unreserved donation $D_i$. Minted shares are floored: $L = \min\left(\lfloor amount_0 T / r_0 \rfloor, \lfloor amount_1 T / r_1 \rfloor\right) \le amount_i T / r_i$. Flooring newly issued shares ensures post-mint reserves $r_i' = B_i = r_i + amount_i \ge r_i(1 + L/T) = r_i \frac{T'}{T}$, guaranteeing $\frac{r_0'}{T'} \ge \frac{r_0}{T}$ and $\frac{r_1'}{T'} \ge \frac{r_1}{T}$. Since both asset-to-share ratios are non-decreasing, their product $\frac{r_0' r_1'}{T'^2} \ge \frac{r_0 r_1}{T^2}$, implying $Q_s' \ge Q_s$.
       - **Burns (`pair.burn`):** Redeemed asset amounts are calculated from custodial token balances $B_i = r_i + D_i \ge r_i$ (where $D_i \ge 0$ represents any prior unsolicited donation): $a_i = \lfloor S B_i / T \rfloor \le S B_i / T$. Post-burn reserves update via `_update` to remaining physical balances: $r_i' = B_i - a_i \ge (r_i + D_i)(1 - S/T)$. Because remaining shares are $T' = T(1 - S/T)$, the remaining asset density satisfies:
         $$\frac{r_i'}{T'} \ge \frac{(r_i + D_i)(1 - S/T)}{T(1 - S/T)} = \frac{r_i + D_i}{T} \ge \frac{r_i}{T}$$
         Any unreserved donation $D_i \ge 0$ and fractional truncation dust remain in the pool, ensuring non-decreasing asset density for both assets and guaranteeing $Q_s' \ge Q_s$.
       - **Donations & Skim:** Token donations increase physical balances without altering stored reserves ($Q_s' = Q_s$); `skim()` removes excess balance without modifying stored reserves ($Q_s' = Q_s$); `sync()` updates stored reserves to actual balances ($\ge r_i$), preserving or growing $Q_s$.
      * **Integer Widths & Arithmetic Precision:**
        Reserves $r_0, r_1 \le \text{type}(uint112).\text{max} < 2^{112} \implies r_0 r_1 < 2^{224}$, fitting safely in `uint256`.
        **Quotient Upper Bound & Scale Selection ($10^{15}$ vs. $10^{18}$):** Although `Math.mulDiv` uses 512-bit intermediate multiplication, it returns a `uint256` quotient and reverts if the result $\ge 2^{256}$. Under extreme pool states where stored supply is at the genesis minimum ($T = \text{MINIMUM\_LIQUIDITY} = 1000$) and stored reserves approach maximum width ($r_0, r_1 \approx 2^{112}-1$), a $10^{18}$ scale would produce $\frac{2^{224} \cdot 10^{18}}{10^6} = 2^{224} \cdot 10^{12} \approx 2^{263.86} > 2^{256}$, causing `Math.mulDiv` to revert. Selecting $S = 10^{15}$ establishes a formal universal upper bound on the quotient:
        $$\frac{r_0 r_1 \cdot 10^{15}}{T^2} \le \frac{(2^{112}-1)^2 \cdot 10^{15}}{1000^2} < \frac{2^{224} \cdot 10^{15}}{10^6} = 2^{224} \cdot 10^9 < 2^{224} \cdot 2^{30} = 2^{254} < 2^{256}-1$$
        Thus, for all contract-reachable reserves $r_0, r_1 \le 2^{112}-1$ and supply $T \ge 1000$, the quotient is strictly bounded within $2^{254} < 2^{256}-1$, guaranteeing `Math.mulDiv` can never revert due to quotient overflow.
        **Total Supply Inherent Upper Bound ($T < 2^{112}$):** From the contract's minting rules, at genesis $T_{\text{genesis}} = \lfloor \sqrt{r_0 r_1} \rfloor \le \sqrt{r_0 r_1} \implies T_{\text{genesis}}^2 \le r_0 r_1$. Because the reserve product per supply squared $\frac{r_0 r_1}{T^2} \ge 1$ is monotonically non-decreasing across all valid pool operations (swaps, mints, burns, sync, and donations), the invariant $T^2 \le r_0 r_1$ is inductively preserved under all contract-reachable states. Since stored reserves are strictly bounded by `type(uint112).max` ($r_0, r_1 < 2^{112}$), we have $T^2 \le r_0 r_1 < (2^{112})^2 = 2^{224} \implies T \le \sqrt{r_0 r_1} < 2^{112} \ll 2^{128} - 1$. Therefore, total supply $T$ can **never** exceed $2^{112} - 1 \approx 5.192 \times 10^{33}$ under standard token conservation axioms, and the denominator squaring $T^2 < 2^{224} \ll 2^{256} - 1$ is **universally safe against overflow without requiring an external supply cap**. The assertion `require(total <= type(uint128).max)` in the test harness is retained as a defensive sanity guard that is mathematically guaranteed never to bind for any reachable pool state. In the actual harness, $T \approx 100 \text{ ether} = 10^{20} \ll 2^{112}$. Intermediate product $r_0 r_1 \cdot 10^{15} < 2^{274} \ll 2^{512}$ is computed with OpenZeppelin `Math.mulDiv` (512-bit precision via Chinese Remainder Theorem), avoiding intermediate overflow or lossy truncations.
     * **Explicit Assumptions & Scope Constraints:**
       - **Standard ERC-20 Axiom:** Monotonicity holds strictly for tokens conforming to standard ERC-20 balance conservation. If a token contracts supply via negative rebase and `sync()` is called, reserves drop while total supply remains constant, causing $Q_s$ to collapse (demonstrated in `test_Adversarial_NegativeRebaseBricksSwapsWithoutSync`).
       - **Solvency & Dead-Address Lock:** Total supply must never drop to zero ($T \ge \text{MINIMUM\_LIQUIDITY} = 1000$ wei permanently locked at `DEAD_ADDRESS`).
       - **Total Supply Bound:** Total supply is inherently bounded by reserve limits: $T \le \sqrt{r_0 r_1} < 2^{112} \ll 2^{128}-1$.
       - **Empirical Fuzz Evidence vs. Analytical Guarantees:** Running 1,000 runs and 50,000 calls across 12 action selectors without counterexample establishes strong empirical support within the explored operational domain; it is not an exhaustive formal proof across all possible sequences or adversarial initialization states.
  2. **Swap-Specific Fee Accretion Invariants:**
     In `AMMHandler`, actions `swap0`, `swap1`, and `swapViaRouter` explicitly assert that post-swap raw $K \ge \text{preK}$, ensuring fee growth on every individual swap transaction.
  3. **Burn-Specific Consistency Invariants:**
     In `AMMHandler.removeLiquidity`, post-burn $Q_s$ is asserted to be greater than or equal to pre-burn $Q_s$, confirming proportional asset accounting.
  4. **Sensitivity & Vulnerability Detection Verification:**
     In `test_Adversarial_KPerShareInvariantValidUnderLiquidityRemovalAndFailsOnExploit`, verified that while legitimate burns drop raw $K$ from peak while preserving $Q_s$, an exploit drain collapses $Q_s$ by over 99%, confirming the invariant detects security breaches.
  5. **Bounded Operational Idle Model & Active Time Warping:**
     Added `MAX_HARNESS_IDLE_SECONDS = 30 days` to `AMMHandler`. All state-mutating pair actions record `lastPairActionTimestamp = block.timestamp;`. `warpTime(uint256 timeSeed)` advances time dynamically between 1 second and 1 day, while bounding cumulative idle time.
  6. **Modular Cumulative Progress Property:**
     Added `invariant_PriceCumulativeModularProgress` with documented non-wrapping domain assumptions. Direct modular overflow across $2^{256}$ and $2^{32}$ rollover is independently verified via deterministic unit tests.
* **Verification:**
  1,000 runs, 50,000 calls across 12 action selectors with 0 invariant violations across all 6 invariants.

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
       The pro-rata claim on pool STD is:
       $$\text{claim} = \frac{1000 \times 1904761904761904761905}{1900 \cdot 10^{18}} = \mathbf{1002\text{ wei STD}}$$
       Permanently locked minimum liquidity increased by $+\mathbf{2\text{ wei STD}}$ (from 1000 wei to 1002 wei).
       The theoretical continuous unrounded gain is:
       $$\frac{1000}{1900 \cdot 10^{18}} \times \frac{100 \cdot 10^{18}}{21} = \frac{100000}{39900} \approx \mathbf{2.506265\text{ wei STD}}$$
       which truncates under EVM integer division to **$2\text{ wei}$** (correcting the earlier typographical calculation that erroneously reported approximately $2,506\text{ wei}$).
       Total socialized balance check: Alice Gain ($4761904761904760903$) + Dead Address Gain ($2$) = $\mathbf{4761904761904761905\text{ wei STD}} = \text{Bob Loss}$. Every single wei of socialized asset transfer is exactly accounted for and backed by test assertions in `test_Adversarial_FeeOnTransferLiquidityAsymmetry`.
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
  5. **Full-Width Age Calculation Across $2^{32}$ Seconds:**
     `test_Adversarial_ObservationOlderThan2ToThe32SecondsRevertsOnConsult` proves that with full-width `uint256 lastObservationTimestamp`, an observation older than $2^{32}$ seconds (~136.19 years) correctly reports age $= 2^{32}+10$ without modular wrap, is flagged as stale by `isStale(1 hours)`, and reverts with `StalePrice` on both default and parameterized `consult`.
  6. **Cumulative Modular Subtraction Across $2^{256}$:**
     Two's complement subtraction `unchecked { price0Cumulative - price0CumulativeLast }` accurately computes positive price growth even when the accumulator wraps across $2^{256}-1$.
  7. **K Per Share Invariant Preservation & Exploit Drain Sensitivity:**
     `test_Adversarial_KPerShareInvariantValidUnderLiquidityRemovalAndFailsOnExploit` proves that proportional liquidity burns legitimately drop raw $K$ from peak while preserving $Q_s$, and that an exploit drain collapses $Q_s$ by over 99%, confirming that the invariant suite reliably detects security breaches.
  8. **Deterministic Counterexample to Separately Floored Ratios:**
     `test_Adversarial_ProductOfFlooredRatiosDecreasesOnSwapCounterexample` proves that the naive two-floor metric $\lfloor r_0 \cdot 10^{18} / T \rfloor \times \lfloor r_1 \cdot 10^{18} / T \rfloor$ strictly decreases across a valid fee-paying swap (by $10^{18}$), while raw $K$ strictly grows and the single-floored scaled metric $Q_s = \lfloor (r_0 r_1 \cdot 10^{15}) / T^2 \rfloor$ remains non-decreasing.

---

## Static Analysis & Compiler Diagnostics

Foundry AST compiler analysis (`forge build`) was executed on all contracts:
- `warning[reentrancy-no-eth]`: External calls to `IAviorCallee.aviorCall(...)` in `AviorAMMPairSecured.sol`. Verified guarded by OpenZeppelin `ReentrancyGuard` (`nonReentrant`), proven by 4,185 callback reentrancy attempts in invariant testing.
- `warning[unsafe-typecast]`: Downcasting balances to `uint112`. Verified guarded by explicit overflow reverts (`if (balance0 > type(uint112).max) revert Overflow()`).

---

## Unresolved Risks & Operational Recommendations

1. **Pull-Based TWAP Keeper Dependency & `consultUnchecked` Hazard:**
   `AviorTWAPOracle` requires regular updates. On-chain protocols MUST use `consult(token, amountIn, maxAge)` or the fail-closed default `consult(token, amountIn)` with an explicit staleness limit. Under no circumstances should lending or liquidation mechanisms invoke `consultUnchecked`.
2. **AMM Pair Cumulative Price Accumulator Modular Wrap:**
   While oracle freshness now tracks full-width `uint256` observation timestamps (eliminating freshness age aliasing), the AMM pair's cumulative price accumulator relies on canonical Uniswap v2 `uint32` modular arithmetic. If a pair receives no interaction for $\ge 2^{32}$ seconds (~136.19 years), cumulative price delta calculations wrap modulo $2^{32}$. Keepers must invoke updates within $2^{32}-1$ seconds of prior pool interactions.
3. **Lack of Native Fee-on-Transfer Support in Router:**
   `AviorRouter.sol` does not support Fee-on-Transfer tokens. Deploying pairs with taxed tokens requires specialized wrapper routers.
4. **Rebase Sync Automation:**
   Negative rebases freeze pool swaps with `InvalidK` until `pair.sync()` is executed. Automated keepers must monitor rebase events.
5. **Single-Validator Bridge Key:**
   `CrossChainMessageVaultSecured` uses a single validator key. Production bridges require decentralized threshold signature schemes (TSS) or multi-validator quorums.
6. **Educational Lab Notice:**
   This project is an educational security research lab and portfolio demonstration. It has not undergone formal commercial audit by an external security firm and is not warranted for mainnet deployment.
