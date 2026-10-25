# Security Audit Report: Flash Swap Reentrancy & Reserve Desynchronization

---

## Finding Summary

| Field | Detail |
| :--- | :--- |
| **Finding ID** | `AVIOR-DEX-001` |
| **Title** | Flash Swap Callback Reentrancy into `sync()` Allows Complete Pool Liquidity Drain |
| **Severity** | **Critical** |
| **CVSS v3.1 Vector** | `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H` (**Score: 9.8**) |
| **Status** | **Confirmed & Mitigated** |
| **Target Component** | Avior AMM Core Pair Contract (`AviorAMMPair`) |
| **Affected Source File** | [`src/dex/AviorAMMPair.sol#L105-L135`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPair.sol) |
| **Fixed Source File** | [`src/dex/AviorAMMPairSecured.sol#L111-L150`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/src/dex/AviorAMMPairSecured.sol) |
| **Exploit Test File** | [`test/dex/AviorAMMPairExploit.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/dex/AviorAMMPairExploit.t.sol) |
| **Regression Test File** | [`test/regressions/AviorAMMPairRegression.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/regressions/AviorAMMPairRegression.t.sol) |
| **Invariant Test File** | [`test/invariants/AviorAMMPairInvariant.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/invariants/AviorAMMPairInvariant.t.sol) |

---

## 1. Vulnerability Overview & Root Cause

### 1.1 Description
The `AviorAMMPair` contract implements a constant-product Automated Market Maker ($x \cdot y = k$) featuring flash swaps via the `IAviorCallee` callback interface. When executing `swap(amount0Out, amount1Out, to, data)`, the contract transfers output tokens to recipient `to` before invoking `aviorCall(sender, amount0Out, amount1Out, data)` if `data.length > 0`.

However, `AviorAMMPair` omits reentrancy guards on `swap()` and `sync()`. Furthermore, its post-swap invariant validation reads stored reserve state rather than immutable pre-execution snapshots:
```solidity
if (balance0 * balance1 < uint256(reserve0) * uint256(reserve1)) revert InvalidK();
```

### 1.2 Root Cause Analysis
1. **Missing Mutex:** Neither `swap()` nor `sync()` utilizes a reentrancy guard (`nonReentrant`).
2. **Intermediate State Exposure:** Tokens are transferred out before verifying repayment. While control is handed to an untrusted external contract via `aviorCall()`, the pair's actual token balances are temporarily reduced.
3. **Storage State Corruption:** Calling `sync()` inside `aviorCall()` forces the pair to overwrite its stored reserves (`reserve0`, `reserve1`) with the depleted token balances (`balanceOf(address(this))`).
4. **Invariant Neutralization:** When execution resumes in `swap()`, the expression `balance0 * balance1 < uint256(reserve0) * uint256(reserve1)` compares depleted balances against newly synchronized depleted reserves. The comparison evaluates to equality ($20 \cdot 100 \not< 20 \cdot 100$), bypassing repayment requirements entirely.

---

## 2. Threat Model & Attack Preconditions

### 2.1 Threat Actor Profile
- **Attacker Privilege:** Completely unprivileged external account.
- **Capital Required:** Zero capital or nominal gas fees; flash swaps require no upfront collateral.
- **EVM Capabilities:** Ability to deploy a custom smart contract implementing `IAviorCallee`.

### 2.2 Attack Surface
- **Entry Point:** `AviorAMMPair.swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data)`
- **Trust Assumption Violated:** The assumption that flash borrowers must return borrowed principal plus fees before transaction completion.

---

## 3. Step-by-Step Attack Scenario

1. **Pre-State:** The pool holds `100 ether` of `token0` and `100 ether` of `token1`. Tracked reserves are `reserve0 = 100 ether`, `reserve1 = 100 ether`.
2. **Step 1 (Initiate Flash Swap):** Attacker calls `pair.swap(80 ether, 0, address(attackContract), bytes("EXPLOIT"))`.
3. **Step 2 (Token Delivery):** `AviorAMMPair` transfers `80 ether` of `token0` to `attackContract`. The pool's actual `token0` balance drops to `20 ether`.
4. **Step 3 (Callback Interception):** `AviorAMMPair` executes `IAviorCallee(attackContract).aviorCall(...)`.
5. **Step 4 (Reentrant State Desynchronization):** Inside `aviorCall()`, `attackContract` calls `pair.sync()`. `sync()` executes `_update(balance0, balance1)`:
   - `reserve0` is updated from `100 ether` to `20 ether`.
   - `reserve1` remains `100 ether`.
6. **Step 5 (Zero-Repayment Return):** `attackContract` returns from `aviorCall()` without transferring any tokens back to `AviorAMMPair`.
7. **Step 6 (Bypassed Invariant Check):** `AviorAMMPair` evaluates:
   $$\text{balance0} \times \text{balance1} = 20 \times 100 = 2000$$
   $$\text{reserve0} \times \text{reserve1} = 20 \times 100 = 2000$$
   Because $2000 \not< 2000$, the invariant check passes, `_update()` confirms reserves at `20 ether`, and execution terminates successfully.
8. **Impact:** Attacker retains `80 ether` of `token0` for zero cost; LP liquidity is permanently stolen.

---

## 4. Minimal Reproducible Proof of Concept (PoC)

### 4.1 Reproducing Code Snippet
From [`test/dex/AviorAMMPairExploit.t.sol`](file:///c:/Users/dogga/My-first-smart-contract-audit-lab/test/dex/AviorAMMPairExploit.t.sol):
```solidity
function test_Exploit_FlashSwapReentrancySyncDrain() public {
    ReentrantCallee attackContract = new ReentrantCallee(address(pair), address(token0), address(token1));
    uint256 drainAmount0 = 80 ether;

    vm.prank(attacker);
    pair.swap(drainAmount0, 0, address(attackContract), bytes("EXPLOIT"));

    assertEq(token0.balanceOf(address(attackContract)), 80 ether);
    (uint112 r0After, uint112 r1After,) = pair.getReserves();
    assertEq(r0After, 20 ether);
}
```

### 4.2 Exact Execution Command
```bash
forge test -vvv --match-test test_Exploit_FlashSwapReentrancySyncDrain
```

### 4.3 Verified Test Execution Output
```text
Ran 1 test for test/dex/AviorAMMPairExploit.t.sol:AviorAMMPairExploitTest
[PASS] test_Exploit_FlashSwapReentrancySyncDrain() (gas: 471704)
Logs:
  === VULNERABILITY REPRODUCTION: REENTRANT SYNC DRAIN ===
  Initial Reserve0: 100000000000000000000
  Drained Amount0 : 80000000000000000000
  Post-Exploit Reserve0: 20000000000000000000
  Attacker Stolen Balance: 80000000000000000000

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 13.87ms
```

---

## 5. Realistic Impact & Risk Assessment

- **Direct Financial Impact:** 100% drainage of any token reserves up to the single-transaction liquidity limit.
- **LP Insolvency:** Legitimate liquidity providers cannot withdraw their deposited tokens because the underlying asset backing has been removed.
- **DEX Contagion:** Any lending protocol, arbitrage bot, or automated vault relying on this pair's spot price or reserves faces immediate cascading liquidations or bad debt.

---

## 6. Recommended Remediation

### 6.1 Architectural Solution
1. **Apply `ReentrancyGuard`:** Apply OpenZeppelin's `nonReentrant` modifier to `swap()`, `mint()`, `burn()`, `sync()`, and `skim()`.
2. **Strict Fee-Adjusted K Invariant:** Enforce Uniswap v2's strict fee accounting:
   $$(1000 \cdot \text{balance}_0 - 3 \cdot \text{amount0In}) \times (1000 \cdot \text{balance}_1 - 3 \cdot \text{amount1In}) \ge 1000^2 \times \text{reserve0} \times \text{reserve1}$$
3. **Lock Initial Liquidity:** On genesis mint, burn `MINIMUM_LIQUIDITY` (1000 units) to address `0xdEaD` to neutralize first-depositor share inflation attacks.

### 6.2 Remediation Code Diff
```diff
- contract AviorAMMPair is ERC20 {
+ contract AviorAMMPairSecured is ERC20, ReentrancyGuard {

-     function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external {
+     function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
          ...
-         if (balance0 * balance1 < uint256(reserve0) * uint256(reserve1)) revert InvalidK();
+         uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
+         uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
+         if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
+
+         uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
+         uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
+         if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * uint256(_reserve1) * (1000 ** 2)) {
+             revert InvalidK();
+         }
      }

-     function sync() external {
+     function sync() external nonReentrant {
          _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
      }
```

---

## 7. Regression Validation & Invariant Testing

### 7.1 Regression Test Outcome
Command executed:
```bash
forge test -vvv --match-test test_Regression_ReentrantSyncBlockedByGuard
```
Output:
```text
Ran 1 test for test/regressions/AviorAMMPairRegression.t.sol:AviorAMMPairRegressionTest
[PASS] test_Regression_ReentrantSyncBlockedByGuard() (gas: 357037)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 138.79ms
```
The test verifies that an attacker contract attempting to call `sync()` during `aviorCall()` immediately reverts with `ReentrancyGuardReentrantCall()`, leaving pool reserves completely intact.

### 7.2 Invariant Test Outcome
Command executed:
```bash
forge test -vvv --match-contract AviorAMMPairInvariantTest
```
Output:
```text
Ran 1 test for test/invariants/AviorAMMPairInvariant.t.sol:AviorAMMPairInvariantTest
[PASS]
AviorAMMPairInvariantTest invariants:
[PASS] invariant_KIsPreservedOrGrown
[PASS] invariant_PermanentMinimumLiquidityPreserved
[PASS] invariant_ReservesCoveredByTokenBalances
 AviorAMMPairInvariantTest invariants (runs: 1000, calls: 50000, reverts: 285)
```
Across 1000 runs and 50,000 random calls (swaps, liquidity deposits, withdrawals, syncs), all three AMM invariants held continuously without a single failure.

---

## 8. Known Limitations & Residual Risks

- **Flash Loan Fees:** The 0.3% fee model protects LP earnings during swaps and flash loans. However, protocols integrating flash swaps must ensure slippage parameters are enforced off-chain.
- **Fee-On-Transfer Tokens:** If tokens take a fee on transfer, the pair's balance delta must be verified before and after transfers to prevent reserve desynchronization.
