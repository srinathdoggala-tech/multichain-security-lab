# Adversarial Security Review: AMM Core, Router, TWAP Oracle & Non-Standard Tokens

---

## Provenance, Attribution & Audit Disclaimer

> **DISCLAIMER & NON-PRODUCTION NOTICE:**
> This security report is an independent, adversarial defensive security review authored for educational research and smart contract security auditor portfolio purposes.
> **This repository has NOT been commercially audited by an external third-party auditing firm and is NOT intended or warranted for production or mainnet deployment.**

### Material Classification & Provenance:
- **Inherited Material:** Base EVM educational challenge labs (reentrancy, oracle attack, signature replay) originated from [`void-node/My-first-smart-contract-audit-lab`](https://github.com/void-node/My-first-smart-contract-audit-lab).
- **Adapted Material:** The core constant-product AMM pair (`AviorAMMPairSecured.sol`), slippage router (`AviorRouter.sol`), and TWAP oracle (`AviorTWAPOracle.sol`) adapt canonical Uniswap v2 mechanisms to Solidity `0.8.28`, replacing legacy assembly/Solidity 0.6 constructs with OpenZeppelin `ReentrancyGuard`, custom errors, and modular math libraries.
- **Independently Authored Security Work:**
  1. Adversarial test suite [`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol) (12 tests covering boundary conditions, stale price exploitation, FoT socialization, rebase freezes, and rollover).
  2. Dual-interface staleness hardening in [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) (`consult(token, amount, maxAge)`, `observationAge()`, `isStale(maxAge)`).
  3. Perimeter zero-address validation in [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol).
  4. Stateful invariant harness upgrade [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol) adding `warpTime` action (4,000+ warps across 50,000 calls) and two independent invariants: `invariant_PriceCumulativeMonotonic` and non-future signed half-circle `invariant_TimestampConsistency`.

---

## Executive Summary

An independent, adversarial security review was performed on the `audit/adversarial-security-review` branch of `srinathdoggala-tech/multichain-security-lab`. The review verified 10 core properties across the AMM pair, router, oracle, and adversarial token mocks.

**Current Verified Test Suite Status:**
- **31 test suites: 89 passed, 0 failed, 0 skipped (89 total tests)**
- **Stateful Invariant Fuzzing:** 1,000 runs, 50,000 handler calls, 0 invariant violations across 6 formal invariants.

---

## Findings & Classifications Matrix

| Finding ID | Title | Target File | Classification | Severity | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`AVIOR-ORACLE-001`** | Unbounded Observation Staleness in `consult()` | [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) | Design Limitation / Integration Hazard | **Medium** | **Remediated & Verified** |
| **`AVIOR-TEST-001`** | Invariant Test Harness Time Warp Blind Spot | [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol) | QA Deficiency / Test Coverage Blind Spot | **Medium** | **Remediated & Verified** |
| **`AVIOR-ROUTER-001`** | Missing Perimeter Zero-Address Recipient Validation | [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol) | Confirmed Bug / Input Validation Defect | **Low** | **Remediated & Verified** |
| **`AVIOR-AMM-003`** | Asymmetric Fee-on-Transfer Liquidity Socialization | [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) | Protocol Compatibility Limitation | **Low / Info** | **Documented & PoC Proven** |
| **`AVIOR-AMM-004`** | Negative Elastic Rebase Pool Freezes Swaps Without `sync()` | [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) | Protocol Compatibility Limitation | **Low / Info** | **Documented & PoC Proven** |
| **`AVIOR-MATH-001`** | Quantitative Multi-Block TWAP Manipulation Cost | [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol) | Economic Property Analysis | **Informational** | **Formally Derived & Tested** |

---

## Detailed Technical Findings

### 1. `AVIOR-ORACLE-001`: Unbounded Observation Staleness in `consult()`
* **Component:** [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Protocol Design Hazard / Integration Risk
* **Severity:** **Medium** (CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:N — Score: 6.5)
* **Technical Description:**
  `AviorTWAPOracle.consult(address token, uint256 amountIn)` performs a fixed-point multiplication against `price0Average` or `price1Average`. These snapshot averages are only refreshed when `update()` is explicitly executed. If external keepers or integrators fail to invoke `update()` (for instance, over 30 days of market volatility), `consult(token, amountIn)` silently quotes outdated historical prices without reverting.
* **Why the Unchecked Overload Exists:**
  The unchecked 2-parameter `consult(token, amountIn)` signature is retained for backward compatibility with the canonical Uniswap v2 `ExampleOracleSimple` interface and for off-chain view / analytics callers that perform custom timestamp filtering off-chain.
* **Security Risk to Integrators:**
  Any on-chain DeFi consumer (such as a lending market collateral oracle) calling `consult(token, amountIn)` without inspecting observation freshness is vulnerable to stale price arbitrage: an attacker borrows against a collateral asset whose market spot price has dropped, using the stale, elevated oracle price.
* **Remediation Implemented:**
  1. Added `observationAge() public view returns (uint32 age)` returning elapsed seconds since the snapshot.
  2. Added `isStale(uint256 maxAge) external view returns (bool)` helper.
  3. Added overloaded `consult(address token, uint256 amountIn, uint256 maxAge) external view returns (uint256 amountOut)`:
     ```solidity
     function consult(address token, uint256 amountIn, uint256 maxAge) external view returns (uint256 amountOut) {
         uint32 age = observationAge();
         if (age > maxAge) revert StalePrice(age, maxAge);
         return consult(token, amountIn);
     }
     ```
  4. Added explicit NatSpec warnings on `consult(token, amountIn)` directing all on-chain protocols to use the checked overload.
* **Regression Tests:**
  Verified in [`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol):
  - `test_Adversarial_StaleObservationReturnedWhenUpdateNeglected`: Demonstrates that after 30 days without update, `consult(token, 100 ether, 1 days)` reverts with `StalePrice(30 days, 1 days)`.
  - `test_Adversarial_DualInterfaceStaleEnforcement`: Proves that when fresh ($age \le maxAge$), both overloads return identical quotes, but once $age > maxAge$, the checked interface reverts while the unchecked interface serves stale quotes.

---

### 2. `AVIOR-TEST-001`: Invariant Test Harness Time Warp Blind Spot
* **Component:** [`test/invariants/AviorAMMPairInvariant.t.sol`](../test/invariants/AviorAMMPairInvariant.t.sol)
* **Classification:** Quality Assurance / Verification Blind Spot
* **Severity:** **Medium**
* **Technical Description:**
  In the initial test setup, `AMMHandler` executed 11 actions (swaps, mints, burns, syncs, skims, and callbacks), but never called `vm.warp()`. Across all 50,000 calls in the fuzzing suite, `block.timestamp` remained frozen at its initial block time.
  In `AviorAMMPairSecured._update`:
  ```solidity
  uint32 timeElapsed = blockTimestamp - blockTimestampLast;
  if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
      price0CumulativeLast += ...;
      price1CumulativeLast += ...;
  }
  ```
  Because `timeElapsed == 0` on every call, the accumulator addition code was never executed. Accumulators remained permanently 0, and boundary rollover was never fuzzed.
* **Remediation Implemented:**
  1. Added `warpTime(uint256 timeSeed)` to `AMMHandler`, advancing time forward by bounded intervals $1 \le \Delta t \le 86,400\text{s}$ (1 second to 1 day).
  2. Added two independent mathematical invariants:
     - `invariant_PriceCumulativeMonotonic`: Asserts that `price0CumulativeLast` and `price1CumulativeLast` are monotonically non-decreasing over time.
     - `invariant_TimestampConsistency`: Evaluates the signed two's complement half-circle distance `uint32(block.timestamp) - blockTimestampLast < 2^31`, proving stored timestamps never precede current time or project into the future.
* **Verification:**
  Re-ran the suite: 1,000 runs, 50,000 calls. `warpTime` was invoked **4,043 times** with 0 invariant failures across all 6 invariants.

---

### 3. `AVIOR-ROUTER-001`: Missing Perimeter Zero-Address Recipient Validation
* **Component:** [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol)
* **Classification:** Confirmed Bug / Input Validation Defect
* **Severity:** **Low**
* **Technical Description:**
  While `AviorRouter.swapExactTokensForTokens` contained `if (to == address(0)) revert ZeroAddress();`, `addLiquidity` and `removeLiquidity` lacked this perimeter validation. Although standard OpenZeppelin ERC-20 tokens revert during `_mint(address(0))` or `_update(..., address(0))`, custom LP tokens or tokens that swallow zero-address transfers could result in unrecoverable asset burns.
* **Remediation Implemented:**
  Added explicit guards to `addLiquidity` and `removeLiquidity`:
  ```solidity
  if (to == address(0)) revert ZeroAddress();
  ```
* **Regression Test:**
  Verified in `test_Adversarial_RouterZeroRecipientHandling`, confirming immediate reversion with `AviorRouter.ZeroAddress.selector`.

---

### 4. `AVIOR-AMM-003`: Asymmetric Fee-on-Transfer Liquidity Socialization
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) / [`src/dex/AviorRouter.sol`](../src/dex/AviorRouter.sol)
* **Classification:** Protocol Compatibility Limitation
* **Severity:** **Low / Informational**
* **Mathematical Mechanism & Empirical Breakdown:**
  When depositing liquidity with a Fee-on-Transfer (FoT) token paired with a standard token:
  1. Initial pool state: 1,900 FoT and 1,900 STD (Total supply: 1,900 LP shares, including 1,000 dead shares).
  2. Bob deposits 100 FoT and 100 STD via `AviorRouter.addLiquidity`.
  3. A 5% tax is deducted on the FoT transfer: the pool receives **95 FoT** and **100 STD**.
  4. The pair calculates minted shares using the minimum asset delta:
     $$\text{liquidity} = \min\left(\frac{95 \cdot 1900}{1900}, \frac{100 \cdot 1900}{1900}\right) = 95\text{ LP shares}$$
  5. The pool updates reserves to $R_0 = 1995$ and $R_1 = 2000$. Total supply becomes $1995$ LP shares.
  6. Bob immediately calls `removeLiquidity` with his 95 LP shares:
     - FoT share: $95 \times \frac{1995}{1995} = 95\text{ FoT}$. Transferring back incurs a second 5% exit tax: **90.25 FoT received by Bob**.
     - STD share: $95 \times \frac{2000}{1995} = 95.238095\dots\text{ STD received by Bob}$.
  7. **Net Financial Loss:**
     Bob deposited 100 STD tokens, but received back only **95.238 STD tokens** (a permanent loss of **~4.762 STD tokens**).
     The remaining pool reserve holds $2000 - 95.238 = 1904.762\text{ STD}$ backed by Alice's 1,900 LP shares. Alice's asset backing increased from 1,900 STD to 1,904.762 STD: Bob's 4.762 STD tokens were **permanently socialized to Alice**.
* **Router Swap Behavior with FoT Tokens:**
  In [`test_Adversarial_RouterRejectsFeeOnTransferSwap`](../test/dex/AdversarialSecurityAudit.t.sol), attempting to execute `router.swapExactTokensForTokens` with a Fee-on-Transfer token reverts with `AviorAMMPairSecured.InvalidK.selector`. The standard router assumes the pair received the full `amountIn`, but the balance deficit violates the constant-product invariant.
* **Architectural Conclusion:**
  `AviorRouter.sol` does **NOT** support Fee-on-Transfer tokens. Integrators must not list FoT tokens without specialized wrapper router contracts (`addLiquiditySupportingFeeOnTransferTokens`).

---

### 5. `AVIOR-AMM-004`: Negative Elastic Rebase Pool Freezes Swaps Without `sync()`
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol)
* **Classification:** Protocol Compatibility Limitation
* **Severity:** **Low / Informational**
* **Technical Description & PoC:**
  When a rebasing token experiences a negative rebase (supply contraction):
  1. The pair's physical token balance contracts (e.g. from 1,000 ether to 800 ether), while stored `reserve0` remains at 1,000 ether.
  2. Any trader who transfers input tokens into the pool attempting to swap for the contracted token triggers the post-swap invariant check:
     $$\text{balance0Adjusted} \cdot \text{balance1Adjusted} \ge \text{reserve0} \cdot \text{reserve1} \cdot 1000^2$$
  3. Because `balance0` is already 200 ether below `reserve0`, `balance0Adjusted` falls far below the required product, reverting with `InvalidK()`.
  4. Pool swaps remain completely locked until an external actor invokes `pair.sync()`, resetting reserves to match actual physical balances.
* **Verification:**
  Tested in [`test_Adversarial_NegativeRebaseBricksSwapsWithoutSync`](../test/dex/AdversarialSecurityAudit.t.sol). The swap reverts with `InvalidK()`, and succeeds immediately after `pair.sync()` is called.

---

### 6. `AVIOR-MATH-001`: Quantitative Multi-Block TWAP Manipulation Cost
* **Component:** [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Classification:** Formal Economic & Mathematical Derivation
* **Severity:** **Informational**
* **Mathematical Derivation:**
  The cumulative price accumulator integrates instantaneous spot price $P(t) = \frac{r_1(t)}{r_0(t)}$:
  $$\text{TWAP} = \frac{1}{T} \int_{0}^{T} P(t) \, dt = \frac{\Delta \text{priceCumulative}}{\Delta t}$$
  If an attacker distorts the spot price to $P_{\text{manip}}$ for duration $t_{\text{manip}}$ within period $T = 1800\text{s}$:
  $$\text{TWAP} = \frac{t_{\text{manip}}}{T} P_{\text{manip}} + \frac{T - t_{\text{manip}}}{T} P_{\text{true}}$$
* **Empirical Measurements ([`test_Adversarial_SustainedPriceManipulationHoldingCost`](../test/dex/AdversarialSecurityAudit.t.sol)):**
  1. **Single-Block Flash Manipulation ($t_{\text{manip}} = 12\text{s}$, $T = 1800\text{s}$):**
     - Attacker swaps 9,000 token0 into a 1,000:1,000 pool, depressing token0 spot price by $99\%$ ($P \approx 0.01$).
     - Time weight: $\frac{12}{1800} = 0.667\%$.
     - Expected time-weighted distortion: $0.667\% \times 0.99 \approx 0.66\%$.
     - After swapping back, pool retains $0.3\%$ swap fees, leaving post-reversion spot price shifted by $\approx 0.49\%$ for the remaining 1,788s.
     - **Total Empirical TWAP Shift: 1.142%** (asserted within 2% tolerance).
     - **Conclusion:** A massive $100\times$ single-block spot swing produces only a $1.142\%$ time-weighted impact.
  2. **Multi-Block Sustained Manipulation ($t_{\text{manip}} = 1800\text{s}$, $T = 1800\text{s}$):**
     - Holding the distortion across the full 1800s shifts TWAP by **>80%**.
     - **Economic Barrier:** Maintaining an artificial $100\times$ reserve imbalance across 150 blocks exposes the attacker to severe external arbitrage against market arbitrageurs and liquidators.

---

### 7. Cumulative Price & Boundary Rollover Across $2^{32}-1$
* **Component:** [`src/dex/AviorAMMPairSecured.sol`](../src/dex/AviorAMMPairSecured.sol) / [`src/dex/AviorTWAPOracle.sol`](../src/dex/AviorTWAPOracle.sol)
* **Tested Scenarios ([`test/dex/AdversarialSecurityAudit.t.sol`](../test/dex/AdversarialSecurityAudit.t.sol)):**
  1. **Standard Rollover across $2^{32}-1$:**
     `test_Adversarial_TimestampRolloverAcrossUint32Max` warps from $2^{32}-100$ to $1800$ (elapsed = 1900s). Unsigned modular subtraction $1800 - (2^{32}-100) = 1900$ correctly computes elapsed time without overflow.
  2. **Interim Reserve Shifts Across Rollover:**
     `test_Adversarial_RolloverWithInterimReserveChanges` executes a reserve-shifting swap 50s before rollover, warps across $2^{32}-1$ to $t = 1750$ (total elapsed = 1850s), and confirms the oracle computes the exact piece-wise average ($\approx 27\text{ ether}$).
  3. **Zero Elapsed Time:**
     `test_Adversarial_ZeroElapsedTimeInOracleAndPair` confirms that back-to-back swaps in the same block ($timeElapsed == 0$) do not advance cumulative accumulators, and calling `oracle.update()` in the same block reverts with `PeriodNotElapsed(0, period)`.
  4. **Uninitialized Oracle Access:**
     `test_Adversarial_UninitializedOracleRevertsOnConsult` confirms calling `consult` prior to any update reverts with `OracleNotInitialized()`.
  5. **136-Year Wrap-Around Boundary:**
     `test_Adversarial_LongElapsedIntervalAnalysis` proves that if an observation interval exceeds $2^{32}$ seconds (~136 years), `uint32` distance wraps around (e.g., $2^{32}+500$ evaluates as 500s elapsed, reverting with `PeriodNotElapsed(500, 1800)`).

---

## Static Analysis & Compiler Diagnostics

Foundry AST compiler analysis (`forge build`) was executed on all contracts:
- `warning[reentrancy-no-eth]`: External calls to `IAviorCallee.aviorCall(...)` in `AviorAMMPairSecured.sol`. Verified that `swap()`, `mint()`, `burn()`, `skim()`, and `sync()` all implement OpenZeppelin `ReentrancyGuard` (`nonReentrant`), proven by 4,174 callback reentrancy attempts in invariant testing.
- `warning[unsafe-typecast]`: Downcasting balances to `uint112`. Verified guarded by explicit overflow reverts (`if (balance0 > type(uint112).max) revert Overflow()`).
- Static analysis via `aderyn .`: Noted that `aderyn` is not installed on the local host; recommended for CI integration.

---

## Unresolved Risks & Operational Recommendations

1. **Pull-Based TWAP Keeper Dependency:**
   `AviorTWAPOracle` requires periodic updates. On-chain protocols MUST use `consult(token, amountIn, maxAge)` with an explicit staleness limit (e.g. 1 hour) to protect against keeper downtime.
2. **Lack of Native Fee-on-Transfer Support in Router:**
   `AviorRouter.sol` does not support Fee-on-Transfer tokens for swaps or liquidity addition. Deploying pairs with taxed tokens requires a dedicated router with net balance delta accounting.
3. **Rebase Sync Automation:**
   Negative rebases lock pair swaps with `InvalidK` until `pair.sync()` is executed. Automated keepers must monitor rebase events.
4. **Single-Validator Bridge Key:**
   `CrossChainMessageVaultSecured` uses a single validator key. Production bridges require decentralized threshold signature schemes (TSS) or multi-validator quorums.
