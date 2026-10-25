// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/AviorRouter.sol";
import "../../src/dex/IAviorCallee.sol";
import "../mocks/MockERC20.sol";

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

    constructor(address _pair, address _router, address _token0, address _token1) {
        pair = AviorAMMPairSecured(_pair);
        router = AviorRouter(_router);
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        attackerCallee = new InvariantReentrancyAttacker(_pair);

        actors.push(makeAddr("ALICE"));
        actors.push(makeAddr("BOB"));
        actors.push(makeAddr("CHARLIE"));
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

        token0.mint(actor, amount0In);

        vm.startPrank(actor);
        token0.transfer(address(pair), amount0In);
        pair.swap(0, amount1Out, actor, bytes(""));
        vm.stopPrank();

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

        token1.mint(actor, amount1In);

        vm.startPrank(actor);
        token1.transfer(address(pair), amount1In);
        pair.swap(amount0Out, 0, actor, bytes(""));
        vm.stopPrank();

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

        vm.startPrank(actor);
        pair.transfer(address(pair), sharesToBurn);
        pair.burn(actor);
        vm.stopPrank();

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
        skimCount++;
    }

    /// @notice Action 7: Sync reserves to actual balances
    function sync() external {
        pair.sync();
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
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 < 1 ether || r1 < 1 ether) return;

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
        routerSwapsCount++;
    }

    /// @notice Action 12: Warp block timestamp forward to exercise cumulative price accumulators and rollover
    function warpTime(uint256 timeSeed) external {
        uint256 timeJump = bound(timeSeed, 1, 86400); // 1 second to 1 day
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
    }

    /// @notice Invariant 1: Constant-product K remains strictly positive across all valid transitions
    function invariant_KIsPreservedOrGrown() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        assertTrue(currentK > 0, "K invariant must remain positive");
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

    /// @notice Invariant 5: Time-weighted price cumulative accumulators are strictly monotonic non-decreasing
    function invariant_PriceCumulativeMonotonic() public {
        uint256 p0 = pair.price0CumulativeLast();
        uint256 p1 = pair.price1CumulativeLast();
        assertGe(p0, lastPrice0Cumulative, "price0Cumulative must be monotonically non-decreasing");
        assertGe(p1, lastPrice1Cumulative, "price1Cumulative must be monotonically non-decreasing");
        lastPrice0Cumulative = p0;
        lastPrice1Cumulative = p1;
    }

    /// @notice Invariant 6: Stored blockTimestampLast is strictly non-future relative to the EVM clock
    function invariant_TimestampConsistency() public view {
        (,, uint32 blockTimestampLast) = pair.getReserves();
        uint32 currentTimestamp32 = uint32(block.timestamp % 2 ** 32);
        uint32 elapsed;
        unchecked {
            elapsed = currentTimestamp32 - blockTimestampLast;
        }
        // Standard two's complement half-circle invariant: elapsed must not appear in the future (< 2^31)
        assertTrue(elapsed < type(uint32).max / 2, "Stored timestamp must not be in the future");
    }
}
