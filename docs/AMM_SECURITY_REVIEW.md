# In-Depth AMM Security Architecture & Code Review

**Auditor:** Senior Smart Contract Security Engineer  
**Target:** `AviorAMMPair.sol` & `AviorAMMPairSecured.sol`  
**Standard Reference:** Uniswap v2 Constant Product Market Maker ($x \cdot y = k$)  
**Focus:** Economic Invariant Soundness, Callback Reentrancy, Reserve Synchronization, Genesis Share Inflation

---

## 1. Economic & Invariant Model

The Avior AMM Core implements the classic constant-product market maker formula:
$$k = R_0 \times R_1$$

Where:
- $R_0, R_1$ represent the stored reserves of `token0` and `token1`.
- $B_0, B_1$ represent the contract's actual token balances queryable via `balanceOf(address(this))`.
- Each swap charges a gross trading fee of **0.30%** (30 basis points) on the input token, retained directly in pool reserves for liquidity providers.

### The Canonical Fee-Adjusted Invariant
When a trader sends $\Delta x_{\text{in}}$ and receives $\Delta y_{\text{out}}$, the input amount net of fee is $0.997 \cdot \Delta x_{\text{in}}$. In integer arithmetic (scaled by 1,000 to eliminate floating point rounding), the condition that the pair must verify post-swap is:
$$(1000 \cdot B_0 - 3 \cdot \Delta x_{\text{in}}) \times (1000 \cdot B_1 - 3 \cdot \Delta y_{\text{in}}) \ge 1000^2 \times R_0 \times R_1$$

---

## 2. Attack Vectors & Code Review Findings

### 2.1 Vector A: Flash Swap Callback Reentrancy via `sync()`
* **Vulnerable Mechanism ([`AviorAMMPair.sol#L105-L128`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPair.sol#L105-L128)):**
  1. `swap()` executes optimistic token transfer to recipient `to`.
  2. If `data.length > 0`, it calls `IAviorCallee(to).aviorCall(...)`.
  3. No reentrancy mutex is active.
  4. While tokens are out, the attacker calls `sync()`.
  5. `sync()` sets $R_0 = B_0$ (depleted balance).
  6. In `AviorAMMPair.sol`, the invariant check reads storage variables:
     ```solidity
     if (balance0 * balance1 < uint256(reserve0) * uint256(reserve1)) revert InvalidK();
     ```
  7. Since $R_0$ was updated to $B_0$ during the callback, the inequality evaluates to $B_0 \cdot B_1 < B_0 \cdot B_1$ (false), allowing the transaction to complete with zero repayment.
* **Remediation ([`AviorAMMPairSecured.sol#L111`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPairSecured.sol#L111)):**
  - Inherits OpenZeppelin `ReentrancyGuard`.
  - Marks `swap()`, `mint()`, `burn()`, `sync()`, and `skim()` with `nonReentrant`.
  - Reentrant calls to `sync()` or any mutating function revert with `ReentrancyGuardReentrantCall`.

### 2.2 Vector B: Omission of Swap Fee from Invariant Check
* **Vulnerable Mechanism ([`AviorAMMPair.sol#L124`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPair.sol#L124)):**
  - Checking `balance0 * balance1 >= reserve0 * reserve1` allows zero-fee swaps.
  - Arbitrageurs can oscillate pool prices infinitely without paying protocol or LP fees, gradually draining LP value via rounding arbitrage.
* **Remediation ([`AviorAMMPairSecured.sol#L132-L150`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPairSecured.sol#L132-L150)):**
  - Isolates calculation into `_validateK(...)`.
  - Deducts 3/1000th of input amounts before comparing against $1000^2 \times R_0 \times R_1$.
  - Verified by property fuzzing across 256 random inputs in `testFuzz_SwapPreservesKInvariant`.

### 2.3 Vector C: Genesis Share Inflation & Dilution
* **Vulnerable Mechanism ([`AviorAMMPair.sol#L68-L75`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPair.sol#L68-L75)):**
  - When `totalSupply == 0`, `liquidity = sqrt(amount0 * amount1)`.
  - Attacker deposits 1 wei of each token, receives 1 share, then directly donates 10 ETH of tokens and calls `sync()`.
  - The share price becomes 10 ETH / 1 share.
  - A subsequent depositor depositing 5 ETH computes:
    $$\text{liquidity} = \frac{5\text{ ETH} \times 1\text{ share}}{10\text{ ETH}} = 0$$
  - The deposit mints 0 shares (`InsufficientLiquidityMinted`), reverting or donating their funds.
* **Remediation ([`AviorAMMPairSecured.sol#L75-L81`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPairSecured.sol#L75-L81)):**
  - Permanently locks `MINIMUM_LIQUIDITY = 1000` burned to `address(0xdEaD)` on genesis mint.
  - Inflating 1 share now requires donating $1000 \times$ more capital, making the attack economically unviable.

### 2.4 Vector D: Safe Skim Handling
* **Remediated Mechanism ([`AviorAMMPairSecured.sol#L154-L167`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPairSecured.sol#L154-L167)):**
  - Guards against underflow in Solidity 0.8+ if `balanceOf < reserve`.
  - Bypasses zero-value transfers if `balanceOf == reserve`, avoiding reverts on tokens that disallow zero-value transfers.

---

## 3. Verified Test Matrix

| Threat Vector | Exploit Test | Regression Test | Verified Outcome |
| :--- | :--- | :--- | :--- |
| **Reentrant sync() Drain** | `test_Exploit_FlashSwapReentrancySyncDrain` | `test_Regression_ReentrantSyncBlockedByGuard` | Reverts with `ReentrancyGuardReentrantCall`. |
| **Zero-Fee Swap Drain** | Demonstrated via zero-fee bypass | `test_Regression_FlashSwapWithoutFeeReverts` | Reverts with `InsufficientInputAmount` or `InvalidK`. |
| **Legitimate Flash Swap** | *(N/A)* | `test_Regression_LegitimateFlashLoanSucceeds` | Fee paid; pool reserve grows by fee. |
| **Genesis Share Inflation**| `test_Exploit_GenesisShareInflationDilution` | `test_Regression_MinimumLiquidityProtectsSubsequentDepositors` | 1000 shares burned to dead address; victim mints pro-rata shares. |
| **K Invariant Preservation**| *(N/A)* | `testFuzz_SwapPreservesKInvariant` | 256 bounded runs confirm $K_{\text{post}} \ge K_{\text{pre}}$. |

---

## 4. Residual Risks & Protocol Boundaries

1. **Fee-On-Transfer Tokens:** If a token charges a fee on transfer, `amountIn` calculated as `balance - (reserve - amountOut)` accurately measures tokens received, but any transfer of tokens *out* by the pair will deliver less than `amountOut` to the recipient unless adjusted.
2. **Rebasing Tokens:** Positive or negative rebasing tokens alter `balanceOf(address(this))` asynchronously outside the pair's logic, requiring external synchronization via `sync()`.
3. **Price Manipulation:** Constant-product spot prices are sensitive to flash loan imbalances. Protocols must never query spot reserves directly as an oracle; TWAP or decentralized off-chain feeds must be utilized.
