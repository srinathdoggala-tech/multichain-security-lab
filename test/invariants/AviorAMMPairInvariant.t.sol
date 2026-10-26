// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/AviorRouter.sol";
import "../../src/dex/IAviorCallee.sol";
import "../mocks/MockERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Malicious callee for testing callback reentrancy attempts in stateful testing
contract InvariantReentrancyAttacker is IAviorCallee {
    AviorAMMPairSecured public immutable targetPair;

    constructor(address _targetPair) {
        targetPair = AviorAMMPairSecured(_targetPair);
    }

    function aviorCall(address, uint256, uint256, bytes calldata data) external override {
        uint8 action = abi.decode(data, (uint8));
        // Attempt forbidden reentrancy on targetPair
        if (action == 0) {
            targetPair.swap(0, 1, address(this), "");
        } else if (action == 1) {
            targetPair.mint(address(this));
        } else if (action == 2) {
            targetPair.burn(address(this));
        } else {
            targetPair.sync();
        }
    }
}

/// @title AMMHandler - Stateful Invariant Action Handler for Avior AMM & Router
contract AMMHandler is Test {
    AviorAMMPairSecured public immutable pair;
    AviorRouter public immutable router;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    InvariantReentrancyAttacker public immutable attackerCallee;

    address[] public actors;
    uint256 public successfulSwaps;
    uint256 public successfulMints;
    uint256 public successfulBurns;
    uint256 public donationCount;
    uint256 public skimCount;
    uint256 public syncCount;
    uint256 public failedSwapsCount;
    uint256 public reentrancyBlockedCount;
    uint256 public routerSwapsCount;
    uint256 public constant MAX_HARNESS_IDLE_SECONDS = 30 days;
    uint256 public lastPairActionTimestamp;

    constructor(address _pair, address _router, address _token0, address _token1) {
        pair = AviorAMMPairSecured(_pair);
        router = AviorRouter(_router);
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        attackerCallee = new InvariantReentrancyAttacker(_pair);

        actors.push(makeAddr("ALICE"));
        actors.push(makeAddr("BOB"));
        actors.push(makeAddr("CHARLIE"));
        lastPairActionTimestamp = block.timestamp;
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Action 1: Direct token0 swap
    function swap0(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 < 1 ether || r1 < 1 ether) return;

        uint256 maxSwap = (uint256(r0) * 30) / 100;
        uint256 amount0In = bound(amountSeed, 1e14, maxSwap);

        uint256 amount0InWithFee = amount0In * 997;
        uint256 numerator = amount0InWithFee * uint256(r1);
        uint256 denominator = (uint256(r0) * 1000) + amount0InWithFee;
        uint256 amount1Out = numerator / denominator;
        if (amount1Out == 0 || amount1Out >= r1) return;

        uint256 preK = uint256(r0) * uint256(r1);
        token0.mint(actor, amount0In);

        vm.startPrank(actor);
        token0.transfer(address(pair), amount0In);
        pair.swap(0, amount1Out, actor, bytes(""));
        vm.stopPrank();

        (uint112 postR0, uint112 postR1,) = pair.getReserves();
        require(uint256(postR0) * uint256(postR1) >= preK, "Swap0 must preserve or grow raw K");

        lastPairActionTimestamp = block.timestamp;
        successfulSwaps++;
    }

    /// @notice Action 2: Direct token1 swap
    function swap1(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 < 1 ether || r1 < 1 ether) return;

        uint256 maxSwap = (uint256(r1) * 30) / 100;
        uint256 amount1In = bound(amountSeed, 1e14, maxSwap);

        uint256 amount1InWithFee = amount1In * 997;
        uint256 numerator = amount1InWithFee * uint256(r0);
        uint256 denominator = (uint256(r1) * 1000) + amount1InWithFee;
        uint256 amount0Out = numerator / denominator;
        if (amount0Out == 0 || amount0Out >= r0) return;

        uint256 preK = uint256(r0) * uint256(r1);
        token1.mint(actor, amount1In);

        vm.startPrank(actor);
        token1.transfer(address(pair), amount1In);
        pair.swap(amount0Out, 0, actor, bytes(""));
        vm.stopPrank();

        (uint112 postR0, uint112 postR1,) = pair.getReserves();
        require(uint256(postR0) * uint256(postR1) >= preK, "Swap1 must preserve or grow raw K");

        lastPairActionTimestamp = block.timestamp;
        successfulSwaps++;
    }

    /// @notice Action 3: Add liquidity
    function addLiquidity(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 amount0 = bound(amountSeed, 1e15, 10 ether);
        uint256 amount1 = (amount0 * uint256(r1)) / uint256(r0);
        if (amount1 == 0) return;

        token0.mint(actor, amount0);
        token1.mint(actor, amount1);

        vm.startPrank(actor);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        uint256 shares = pair.mint(actor);
        vm.stopPrank();

        lastPairActionTimestamp = block.timestamp;
        if (shares > 0) {
            successfulMints++;
        }
    }

    /// @notice Action 4: Remove liquidity
    function removeLiquidity(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _getActor(actorSeed);
        uint256 userShares = pair.balanceOf(actor);
        if (userShares == 0) return;

        uint256 sharesToBurn = bound(shareSeed, 1, userShares);
        (uint112 preR0, uint112 preR1,) = pair.getReserves();
        uint256 preTotal = pair.totalSupply();
        uint256 preKPerShare = Math.mulDiv(uint256(preR0) * uint256(preR1), 1e18, preTotal * preTotal);

        vm.startPrank(actor);
        pair.transfer(address(pair), sharesToBurn);
        pair.burn(actor);
        vm.stopPrank();

        (uint112 postR0, uint112 postR1,) = pair.getReserves();
        uint256 postTotal = pair.totalSupply();
        uint256 postKPerShare = Math.mulDiv(uint256(postR0) * uint256(postR1), 1e18, postTotal * postTotal);
        require(postKPerShare >= preKPerShare, "Burn must preserve or grow K per supply squared");

        lastPairActionTimestamp = block.timestamp;
        successfulBurns++;
    }

    /// @notice Action 5: Direct unsolicited donation of tokens to pair
    function donate(uint256 actorSeed, uint8 tokenChoice, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        uint256 amount = bound(amountSeed, 1e14, 5 ether);
        MockERC20 token = (tokenChoice % 2 == 0) ? token0 : token1;

        token.mint(actor, amount);
        vm.startPrank(actor);
        token.transfer(address(pair), amount);
        vm.stopPrank();

        donationCount++;
    }

    /// @notice Action 6: Skim excess balance
    function skim(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        pair.skim(actor);
        lastPairActionTimestamp = block.timestamp;
        skimCount++;
    }

    /// @notice Action 7: Sync reserves to actual balances
    function sync() external {
        pair.sync();
        lastPairActionTimestamp = block.timestamp;
        syncCount++;
    }

    /// @notice Action 8: Failed swap attempting to extract excessive liquidity (must revert and not mutate state)
    function failedSwapExcessiveOutput(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 r0,,) = pair.getReserves();
        uint256 excessiveOut = uint256(r0) + bound(amountSeed, 1, 50 ether);

        (uint112 pre0, uint112 pre1,) = pair.getReserves();
        vm.startPrank(actor);
        try pair.swap(excessiveOut, 0, actor, "") {
            revert("Excessive swap should revert");
        } catch {
            failedSwapsCount++;
        }
        vm.stopPrank();

        (uint112 post0, uint112 post1,) = pair.getReserves();
        assertEq(pre0, post0, "Failed swap mutated reserve0");
        assertEq(pre1, post1, "Failed swap mutated reserve1");
    }

    /// @notice Action 9: Failed swap requesting zero output (must revert)
    function failedSwapZeroOutput(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 pre0, uint112 pre1,) = pair.getReserves();

        vm.startPrank(actor);
        try pair.swap(0, 0, actor, "") {
            revert("Zero swap should revert");
        } catch {
            failedSwapsCount++;
        }
        vm.stopPrank();

        (uint112 post0, uint112 post1,) = pair.getReserves();
        assertEq(pre0, post0, "Zero output swap mutated reserve0");
        assertEq(pre1, post1, "Zero output swap mutated reserve1");
    }

    /// @notice Action 10: Attempt reentrancy via flash-swap callback (must be cleanly blocked by ReentrancyGuard)
    function attemptReentrantCallback(uint8 action) external {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 < 1 ether || r1 < 1 ether) return;

        bytes memory callbackData = abi.encode(action % 4);
        try pair.swap(0, 1 ether, address(attackerCallee), callbackData) {
            // Must not succeed
            revert("Reentrancy should revert");
        } catch {
            reentrancyBlockedCount++;
        }
    }

    /// @notice Action 11: Execute swap via Router with slippage protection
    function swapViaRouter(uint256 actorSeed, bool zeroForOne, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        uint256 preK;

        {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            if (r0 < 1 ether || r1 < 1 ether) return;
            preK = uint256(r0) * uint256(r1);

            (MockERC20 tIn, MockERC20 tOut, uint112 rIn) = zeroForOne ? (token0, token1, r0) : (token1, token0, r1);
            uint256 amountIn = bound(amountSeed, 1e14, (uint256(rIn) * 20) / 100);

            address[] memory path = new address[](2);
            path[0] = address(tIn);
            path[1] = address(tOut);

            uint256[] memory amounts = router.getAmountsOut(amountIn, path);
            if (amounts[1] == 0) return;

            tIn.mint(actor, amountIn);
            vm.startPrank(actor);
            tIn.approve(address(router), amountIn);
            uint256 preBal = tOut.balanceOf(actor);
            router.swapExactTokensForTokens(amountIn, amounts[1], path, actor, block.timestamp + 100);
            vm.stopPrank();

            require(tOut.balanceOf(actor) - preBal >= amounts[1], "Router slippage invariant violated");
        }

        (uint112 postR0, uint112 postR1,) = pair.getReserves();
        require(uint256(postR0) * uint256(postR1) >= preK, "Router swap must preserve or grow raw K");

        lastPairActionTimestamp = block.timestamp;
        routerSwapsCount++;
    }

    /// @notice Action 12: Warp block timestamp forward within the harness operational bound
    function warpTime(uint256 timeSeed) external {
        uint256 idle = block.timestamp - lastPairActionTimestamp;
        if (idle >= MAX_HARNESS_IDLE_SECONDS) {
            return;
        }
        uint256 remainingIdle = MAX_HARNESS_IDLE_SECONDS - idle;
        uint256 maxJump = remainingIdle > 86400 ? 86400 : remainingIdle;
        uint256 timeJump = bound(timeSeed, 1, maxJump);
        vm.warp(block.timestamp + timeJump);
    }
}

/// @title AviorAMMPairInvariantTest - Stateful Invariant Verification Suite
contract AviorAMMPairInvariantTest is Test {
    AviorAMMPairSecured public pair;
    AviorRouter public router;
    MockERC20 public token0;
    MockERC20 public token1;
    AMMHandler public handler;

    function setUp() public {
        token0 = new MockERC20("Token A", "TKNA", 18);
        token1 = new MockERC20("Token B", "TKNB", 18);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        pair = new AviorAMMPairSecured(address(token0), address(token1));
        router = new AviorRouter();
        router.registerPair(address(token0), address(token1), address(pair));

        // Seed pool with initial liquidity: 100 ether each
        address bootstrap = makeAddr("BOOTSTRAP");
        token0.mint(bootstrap, 100 ether);
        token1.mint(bootstrap, 100 ether);

        vm.startPrank(bootstrap);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(bootstrap);
        vm.stopPrank();

        handler = new AMMHandler(address(pair), address(router), address(token0), address(token1));

        // Target the stateful handler for fuzz iterations
        targetContract(address(handler));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 total = pair.totalSupply();
        lastKPerShare = Math.mulDiv(uint256(r0) * uint256(r1), 1e18, total * total);
    }

    uint256 public lastKPerShare;

    /// @notice Invariant 1: Constant-product reserve density per supply squared (floor(r0 * r1 * 1e18 / total^2)) is monotonically non-decreasing
    /// @dev Raw K = r0 * r1 legitimately decreases on removeLiquidity as assets exit the pool.
    ///      However, the single-floored scaled reserve product per supply squared Q_s = floor((r0 * r1 * 1e18) / total^2)
    ///      is mathematically non-decreasing across all supported state transitions:
    ///      - Swaps: Total LP shares remain constant (T' = T); the 0.3% retained fee ensures post-swap
    ///        r0' * r1' >= r0 * r1, guaranteeing Q_s' >= Q_s without floor-boundary collapse.
    ///      - Proportional liquidity mints: Floored share issuance L = min(floor(a0*T/r0), floor(a1*T/r1)) <= a_i*T/r_i
    ///        ensures r_i' / T' >= r_i / T for both assets, hence Q' >= Q and Q_s' >= Q_s.
    ///      - Proportional liquidity burns: Redeemed asset amounts are floored a_i = floor(liquidity * r_i / T) <= liquidity * r_i / T,
    ///        ensuring remaining reserve density r_i' / T' >= r_i / T, hence Q' >= Q and Q_s' >= Q_s.
    ///      - Direct donations / skim: Physical donations do not change stored reserves until sync(); skim() leaves
    ///        stored reserves unaffected; sync() increases stored reserves to balances (>= r_i), ensuring Q_s' >= Q_s.
    ///      Scope & Assumptions: Standard ERC-20 conservation (no fee-on-transfer, rebasing, or external balance reduction);
    ///      solvency (T >= MINIMUM_LIQUIDITY = 1000 permanently locked at DEAD_ADDRESS); arithmetic computed via Math.mulDiv
    ///      with 512-bit intermediate product to eliminate intermediate truncation or overflow.
    function invariant_KPerSharePreservedOrGrown() public {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 total = pair.totalSupply();
        require(total > 0, "Total supply must be positive");

        uint256 currentKPerShare = Math.mulDiv(uint256(r0) * uint256(r1), 1e18, total * total);
        assertGe(
            currentKPerShare, lastKPerShare, "Reserve product per supply squared must be monotonically non-decreasing"
        );
        lastKPerShare = currentKPerShare;
    }

    /// @notice Invariant 2: Pair ERC-20 balances always equal or exceed stored reserves (backing guarantee)
    function invariant_ReservesCoveredByTokenBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(token0.balanceOf(address(pair)), uint256(r0), "Token0 balance must back reserve0");
        assertGe(token1.balanceOf(address(pair)), uint256(r1), "Token1 balance must back reserve1");
    }

    /// @notice Invariant 3: Genesis MINIMUM_LIQUIDITY lock remains permanently locked in dead address
    function invariant_PermanentMinimumLiquidityPreserved() public view {
        assertEq(
            pair.balanceOf(pair.DEAD_ADDRESS()),
            pair.MINIMUM_LIQUIDITY(),
            "Dead address must permanently hold MINIMUM_LIQUIDITY"
        );
        assertGe(pair.totalSupply(), pair.MINIMUM_LIQUIDITY(), "Total supply cannot drop below minimum liquidity");
    }

    /// @notice Invariant 4: Non-depositors with zero LP shares cannot extract pool assets via burn
    function invariant_ZeroSharesCannotBurnAssets() public {
        address attacker = makeAddr("ZERO_SHARES_ATTACKER");
        assertEq(pair.balanceOf(attacker), 0, "Attacker must have 0 shares");

        vm.startPrank(attacker);
        // Burning 0 transferred shares must revert or produce 0 output
        vm.expectRevert();
        pair.burn(attacker);
        vm.stopPrank();
    }

    uint256 public lastPrice0Cumulative;
    uint256 public lastPrice1Cumulative;

    /// @notice Invariant 5: Time-weighted price cumulative accumulators progress forward in modular arithmetic
    /// @dev Over the bounded fuzz campaign (starting at 0 and accumulating non-negative spot price * timeElapsed),
    ///      the cumulative price is monotonically non-decreasing because:
    ///      1. Spot prices (reserve1 / reserve0) are strictly positive.
    ///      2. Time elapsed is non-negative.
    ///      Scope & Assumption: Monotonicity holds within the non-wrapping domain (cumulative < 2^256).
    ///      Direct modular overflow wrapping across 2^256 and uint32 rollover is verified in AdversarialSecurityAudit.t.sol.
    function invariant_PriceCumulativeModularProgress() public {
        uint256 p0 = pair.price0CumulativeLast();
        uint256 p1 = pair.price1CumulativeLast();
        assertGe(p0, lastPrice0Cumulative, "price0Cumulative must not decrease within non-wrapping domain");
        assertGe(p1, lastPrice1Cumulative, "price1Cumulative must not decrease within non-wrapping domain");
        lastPrice0Cumulative = p0;
        lastPrice1Cumulative = p1;
    }

    /// @notice Invariant 6: Stored blockTimestampLast is strictly non-future relative to the EVM clock
    /// @dev Holds for EVERY sequence permitted by the test harness because idle time without pair interactions
    ///      is strictly bounded by MAX_HARNESS_IDLE_SECONDS (30 days << 2^31).
    function invariant_TimestampConsistency() public view {
        (,, uint32 blockTimestampLast) = pair.getReserves();
        uint32 currentTimestamp32 = uint32(block.timestamp % 2 ** 32);
        uint32 elapsed;
        unchecked {
            elapsed = currentTimestamp32 - blockTimestampLast;
        }
        // Invariant holds for every sequence permitted by the harness:
        assertLe(
            elapsed,
            handler.MAX_HARNESS_IDLE_SECONDS(),
            "Elapsed time between pair updates must not exceed harness operational bound"
        );
        assertTrue(elapsed < 1 << 31, "Stored timestamp must not be in the future");
    }
}
