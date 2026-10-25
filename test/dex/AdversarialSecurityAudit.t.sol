// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/AviorRouter.sol";
import "../../src/dex/AviorTWAPOracle.sol";
import "../../src/dex/libraries/UQ112x112.sol";
import "../mocks/MockERC20.sol";
import "../mocks/FeeOnTransferToken.sol";
import "../mocks/RebasingToken.sol";
import "../mocks/MissingReturnToken.sol";
import "../mocks/ReentrantHookToken.sol";

/// @title AdversarialSecurityAuditTest
/// @notice Independent adversarial test suite evaluating AMM, Router, TWAP Oracle, and Token boundary conditions
contract AdversarialSecurityAuditTest is Test {
    using UQ112x112 for uint224;

    AviorAMMPairSecured public pair;
    AviorRouter public router;
    AviorTWAPOracle public oracle;

    MockERC20 public token0;
    MockERC20 public token1;

    address public alice = makeAddr("ALICE");
    address public bob = makeAddr("BOB");
    address public attacker = makeAddr("ATTACKER");

    uint256 public constant PERIOD = 1800; // 30 minutes

    function setUp() public {
        token0 = new MockERC20("Token A", "TKNA", 18);
        token1 = new MockERC20("Token B", "TKNB", 18);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        pair = new AviorAMMPairSecured(address(token0), address(token1));
        router = new AviorRouter();
        router.registerPair(address(token0), address(token1), address(pair));

        // Bootstrap pool with 1,000 ether each (1:1 price ratio)
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);

        token0.transfer(address(pair), 1_000 ether);
        token1.transfer(address(pair), 1_000 ether);
        pair.mint(address(this));

        // Warp time slightly after genesis mint
        vm.warp(block.timestamp + 10);

        oracle = new AviorTWAPOracle(address(pair), PERIOD);
    }

    // =========================================================================
    // 1. TIMESTAMP ROLLOVER ACROSS 2^32 - 1 (UINT32 OVERFLOW)
    // =========================================================================

    /// @notice Tests that AMM accumulators and TWAP oracle correctly handle timestamp rollover across 2^32 - 1
    function test_Adversarial_TimestampRolloverAcrossUint32Max() public {
        // Warp block.timestamp to 100 seconds before uint32 overflow (2^32 - 100)
        uint256 preRolloverTimestamp = (uint256(1) << 32) - 100;
        vm.warp(preRolloverTimestamp);

        // Update pair and oracle at preRolloverTimestamp
        pair.sync();
        oracle.update();

        assertEq(oracle.blockTimestampLast(), uint32(preRolloverTimestamp));

        // Advance time by 1,900 seconds, wrapping across 2^32 into 1800
        uint256 postRolloverTimestamp = preRolloverTimestamp + 1900;
        vm.warp(postRolloverTimestamp);

        uint32 currentTimestamp32 = uint32(postRolloverTimestamp % 2 ** 32);
        // Modular arithmetic: (2^32 - 100 + 1900) % 2^32 == 1800
        assertEq(currentTimestamp32, uint32(1800));

        // Time elapsed in uint32: 1800 - (2^32 - 100) == 1900
        uint32 timeElapsedUnchecked;
        unchecked {
            timeElapsedUnchecked = currentTimestamp32 - uint32(preRolloverTimestamp);
        }
        assertEq(timeElapsedUnchecked, 1900);

        // Execute oracle update across the rollover boundary
        oracle.update();

        // Verification: Price average must remain 1.0 (2^112) despite the timestamp rollover
        uint224 expectedOne = uint224(1) << 112;
        assertEq(oracle.price0Average(), expectedOne);
        assertEq(oracle.price1Average(), expectedOne);
        assertEq(oracle.blockTimestampLast(), currentTimestamp32);

        // Consult must return exact 1:1 price
        assertEq(oracle.consult(address(token0), 100 ether), 100 ether);
        assertEq(oracle.consult(address(token1), 100 ether), 100 ether);
    }

    // =========================================================================
    // 2. STALE OBSERVATION VULNERABILITY / DESIGN LIMITATION
    // =========================================================================

    /// @notice Proves that if oracle.update() is neglected, consult() returns arbitrary stale prices
    function test_Adversarial_StaleObservationReturnedWhenUpdateNeglected() public {
        // Initial baseline update at t = PERIOD (price is 1:1)
        vm.warp(block.timestamp + PERIOD);
        oracle.update();
        assertEq(oracle.consult(address(token0), 100 ether), 100 ether);

        // Advance time by 30 days without calling update()
        uint256 thirtyDays = 30 * 86400;
        vm.warp(block.timestamp + thirtyDays);

        // Real market moves drastically: a swap shifts pool reserves to 2:1
        token0.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        token0.transfer(address(pair), 1_000 ether);
        // Reserve0 becomes ~2000, Reserve1 drops to ~500 (Price is now ~0.25 token1 per token0)
        uint256 amount1Out = router.getAmountOut(1_000 ether, 1_000 ether, 1_000 ether);
        pair.swap(0, amount1Out, bob, "");
        vm.stopPrank();

        // Check instantaneous spot vs stale TWAP
        uint256 spotPrice = oracle.consultSpot(address(token0), 100 ether);

        // Real market price is ~25 ether:
        assertApproxEqAbs(spotPrice, 25 ether, 1 ether);

        // 1. Calling default consult() (fail-closed with 2 * PERIOD tolerance) REVERTS with StalePrice
        assertEq(oracle.observationAge(), 30 days);
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.StalePrice.selector, 30 days, 2 * PERIOD));
        oracle.consult(address(token0), 100 ether);

        // 2. Calling consult with explicit custom maxAge REVERTS with StalePrice
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.StalePrice.selector, 30 days, 1 days));
        oracle.consult(address(token0), 100 ether, 1 days);

        // 3. Calling consultUnchecked() returns 100 ether (a 30-day stale observation!)
        // Proving why consultUnchecked is explicitly separated and unsafe for lending collateral
        uint256 staleTWAPPrice = oracle.consultUnchecked(address(token0), 100 ether);
        assertEq(staleTWAPPrice, 100 ether);

        // Calling update() brings TWAP to the time-weighted reality
        oracle.update();
        assertEq(oracle.observationAge(), 0);

        // Now consult with staleness protection succeeds
        uint256 refreshedTWAP = oracle.consult(address(token0), 100 ether, 1 days);
        // Over the 30 days, most of the time was at 1:1, so average is close to 100 ether, but includes the shift
        assertLe(refreshedTWAP, 100 ether);
    }

    // =========================================================================
    // 3. SUSTAINED MULTI-BLOCK MANIPULATION MATHEMATICS
    // =========================================================================

    /// @notice Measures TWAP price distortion when an attacker holds a manipulated price for k seconds
    function test_Adversarial_SustainedPriceManipulationHoldingCost() public {
        // Establish baseline TWAP at 1:1 ratio
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Attacker manipulates spot price by 10x using a large swap
        token0.mint(attacker, 10_000 ether);
        vm.startPrank(attacker);
        token0.transfer(address(pair), 9_000 ether);
        uint256 amount1Out = router.getAmountOut(9_000 ether, 1_000 ether, 1_000 ether);
        pair.swap(0, amount1Out, attacker, "");
        vm.stopPrank();

        // Scenario A: Attacker holds the manipulated price for only 12 seconds (1 block)
        vm.warp(block.timestamp + 12);

        // Attacker reverts the manipulation (swapping back)
        token1.mint(attacker, 10_000 ether);
        vm.startPrank(attacker);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        token1.transfer(address(pair), 900 ether);
        uint256 amount0Out = router.getAmountOut(900 ether, r1, r0);
        pair.swap(amount0Out, 0, attacker, "");
        vm.stopPrank();

        // Complete the remaining 1,788 seconds of the period
        vm.warp(block.timestamp + (PERIOD - 12));
        oracle.update();

        // Over 1800s, 12 seconds of manipulation (0.67% of time) only shifts TWAP price by ~1.14%
        uint256 twapAfter12s = oracle.consult(address(token0), 100 ether);
        assertApproxEqRel(twapAfter12s, 100 ether, 0.02e18); // within 2% (empirical delta ~1.14%)

        // Scenario B: Sustained manipulation: Attacker holds manipulated price for full 1800 seconds (100% of period)
        token0.mint(attacker, 10_000 ether);
        vm.startPrank(attacker);
        (r0, r1,) = pair.getReserves();
        token0.transfer(address(pair), 9_000 ether);
        amount1Out = router.getAmountOut(9_000 ether, r0, r1);
        pair.swap(0, amount1Out, attacker, "");
        vm.stopPrank();

        // Hold for the full period (1800 seconds)
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Over the full 1800s at skewed reserves, the TWAP price moves significantly (> 80% deviation)
        uint256 twapAfter1800s = oracle.consult(address(token0), 100 ether);
        assertLt(twapAfter1800s, 20 ether); // Substantially distorted due to 1800s continuous holding
    }

    // =========================================================================
    // 4. ZERO ADDRESS VALIDATION IN ROUTER REMOVAL AND ADDITION
    // =========================================================================

    /// @notice Tests router behavior when to == address(0) in addLiquidity and removeLiquidity
    function test_Adversarial_RouterZeroRecipientHandling() public {
        token0.mint(alice, 100 ether);
        token1.mint(alice, 100 ether);

        vm.startPrank(alice);
        token0.approve(address(router), 100 ether);
        token1.approve(address(router), 100 ether);

        // addLiquidity to address(0) explicitly reverts with ZeroAddress
        vm.expectRevert(AviorRouter.ZeroAddress.selector);
        router.addLiquidity(
            address(token0), address(token1), 10 ether, 10 ether, 9 ether, 9 ether, address(0), block.timestamp + 100
        );

        // Add valid liquidity
        (,, uint256 liquidity) = router.addLiquidity(
            address(token0), address(token1), 10 ether, 10 ether, 9 ether, 9 ether, alice, block.timestamp + 100
        );

        // Now test removeLiquidity to address(0) explicitly reverts with ZeroAddress
        pair.approve(address(router), liquidity);

        vm.expectRevert(AviorRouter.ZeroAddress.selector);
        router.removeLiquidity(
            address(token0), address(token1), liquidity, 1 ether, 1 ether, address(0), block.timestamp + 100
        );
        vm.stopPrank();
    }

    // =========================================================================
    // 5. FEE-ON-TRANSFER ASYMMETRIC LIQUIDITY PROVISIONING
    // =========================================================================

    /// @notice Proves that adding liquidity with fee-on-transfer tokens results in asymmetric token deposit loss
    function test_Adversarial_FeeOnTransferLiquidityAsymmetry() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Taxed", "TAX", 500, makeAddr("TAX_RECIPIENT"));
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0 = address(fot) < address(standard) ? address(fot) : address(standard);
        address t1 = address(fot) < address(standard) ? address(standard) : address(fot);

        AviorAMMPairSecured fotPair = new AviorAMMPairSecured(t0, t1);
        router.registerPair(address(fot), address(standard), address(fotPair));

        // Bootstrap liquidity directly
        fot.mint(alice, 10_000 ether);
        standard.mint(alice, 10_000 ether);

        vm.startPrank(alice);
        fot.transfer(address(fotPair), 2_000 ether); // Pair receives 1,900 ether due to 5% fee
        standard.transfer(address(fotPair), 1_900 ether);
        fotPair.mint(alice);
        vm.stopPrank();

        // Bob attempts to add liquidity via router: 100 fot and 100 standard
        fot.mint(bob, 100 ether);
        standard.mint(bob, 100 ether);

        vm.startPrank(bob);
        fot.approve(address(router), 100 ether);
        standard.approve(address(router), 100 ether);

        // When router transfers 100 fot, pair receives 95 fot (5% tax).
        // Standard token is transferred in full (100 std).
        // Minting formula: liquidity = min(95 * total / 1900, 100 * total / 1900) == 95 LP shares.
        // The remaining 5 standard tokens are absorbed into pool reserves without granting Bob shares.
        (,, uint256 liquidity) = router.addLiquidity(
            address(fot), address(standard), 100 ether, 100 ether, 90 ether, 90 ether, bob, block.timestamp + 100
        );
        vm.stopPrank();

        assertEq(liquidity, 95 ether);

        // Now Bob removes his 95 LP shares:
        // Bob deposited 100 standard tokens, but receives only ~95.238 standard tokens back!
        // ~4.76 standard tokens were permanently socialized and transferred to Alice.
        vm.startPrank(bob);
        fotPair.approve(address(router), liquidity);
        router.removeLiquidity(address(fot), address(standard), liquidity, 0, 0, bob, block.timestamp + 100);
        vm.stopPrank();

        // Check Bob's final token balances:
        // Bob receives 90.25 FoT (suffered 5% fee on deposit, 5% fee on withdrawal = 95 - 4.75 = 90.25)
        assertEq(fot.balanceOf(bob), 90.25 ether);
        // Bob receives only ~95.238 standard tokens instead of the 100 standard tokens he supplied!
        assertApproxEqAbs(standard.balanceOf(bob), 95.238 ether, 0.001 ether);
    }

    // =========================================================================
    // 6. SWAPPING ON REBASING TOKEN POOL AFTER NEGATIVE REBASE WITHOUT SYNC
    // =========================================================================

    /// @notice Proves that a negative rebase without sync() bricks standard swaps due to undercounting amountIn
    function test_Adversarial_NegativeRebaseBricksSwapsWithoutSync() public {
        RebasingToken rebaseToken = new RebasingToken("Elastic", "ELAST", 10_000 ether);
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0;
        address t1;
        if (address(rebaseToken) < address(standard)) {
            t0 = address(rebaseToken);
            t1 = address(standard);
        } else {
            t0 = address(standard);
            t1 = address(rebaseToken);
        }

        AviorAMMPairSecured rebasePair = new AviorAMMPairSecured(t0, t1);
        router.registerPair(address(rebaseToken), address(standard), address(rebasePair));

        rebaseToken.mint(alice, 2_000 ether);
        standard.mint(alice, 2_000 ether);

        vm.startPrank(alice);
        rebaseToken.transfer(address(rebasePair), 1_000 ether);
        standard.transfer(address(rebasePair), 1_000 ether);
        rebasePair.mint(alice);
        vm.stopPrank();

        // Supply contracts by 20% (negative rebase)
        uint256 curSupply = rebaseToken.totalSupply();
        rebaseToken.rebase((curSupply * 80) / 100);

        // Pair's physical balance is now 800, but reserve is still 1,000!
        assertEq(rebaseToken.balanceOf(address(rebasePair)), 800 ether);

        // Bob attempts to swap standard tokens for rebasing tokens without calling sync()
        standard.mint(bob, 50 ether);
        vm.startPrank(bob);
        standard.transfer(address(rebasePair), 50 ether);

        // Because balance of rebaseToken (800) < reserve (1000), any swap expecting rebaseToken out fails
        // If bob requests rebaseToken out:
        uint256 amountOut = 40 ether;
        if (t0 == address(rebaseToken)) {
            // Rebase token is token0, so amount0Out = 40 ether
            // balance0 after transfer = 800 - 40 = 760 ether
            // balance0Adjusted = 760 * 1000 = 760,000
            // reserve0 * 1000 = 1,000,000
            // InvalidK reverts because reserve deficit causes K check failure!
            vm.expectRevert(AviorAMMPairSecured.InvalidK.selector);
            rebasePair.swap(amountOut, 0, bob, "");
        } else {
            vm.expectRevert(AviorAMMPairSecured.InvalidK.selector);
            rebasePair.swap(0, amountOut, bob, "");
        }
        vm.stopPrank();

        // Calling sync() synchronizes reserves down to 800 (and absorbs Bob's prior 50 standard tokens)
        rebasePair.sync();

        // Now Bob performs another swap transferring fresh tokens
        standard.mint(bob, 50 ether);
        vm.startPrank(bob);
        standard.transfer(address(rebasePair), 50 ether);

        (uint112 r0, uint112 r1,) = rebasePair.getReserves();
        uint256 validOut;
        if (t0 == address(rebaseToken)) {
            validOut = router.getAmountOut(50 ether, r1, r0);
            rebasePair.swap(validOut, 0, bob, "");
        } else {
            validOut = router.getAmountOut(50 ether, r0, r1);
            rebasePair.swap(0, validOut, bob, "");
        }
        vm.stopPrank();

        assertGt(validOut, 0);
    }

    // =========================================================================
    // 7. ROBUST ROLLOVER WITH INTERIM RESERVE SHIFTS
    // =========================================================================

    /// @notice Tests cumulative price piece-wise integration when reserves change across uint32 rollover
    function test_Adversarial_RolloverWithInterimReserveChanges() public {
        uint256 preRolloverTimestamp = (uint256(1) << 32) - 100;
        vm.warp(preRolloverTimestamp);

        pair.sync();
        oracle.update();

        // 50 seconds before rollover, execute a swap altering reserves
        vm.warp(preRolloverTimestamp + 50); // t = 2^32 - 50
        token0.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        token0.transfer(address(pair), 1_000 ether);
        uint256 amount1Out = router.getAmountOut(1_000 ether, 1_000 ether, 1_000 ether);
        pair.swap(0, amount1Out, bob, "");
        vm.stopPrank();

        // Warp across rollover boundary to post-rollover timestamp 1750
        // Total elapsed time = 50s (pre-swap at 1:1) + 1800s (post-swap at skewed) = 1850s
        uint256 postRolloverTimestamp = preRolloverTimestamp + 1850;
        vm.warp(postRolloverTimestamp);

        // Update oracle across the rollover boundary
        oracle.update();

        // Verify that oracle price reflects the piece-wise weighted average:
        // 50s at 1.0, 1800s at ~0.25 (reserve1 ~ 500, reserve0 ~ 2000)
        uint256 twapPrice = oracle.consult(address(token0), 100 ether);
        // Weighted average: (50 * 100 + 1800 * 25) / 1850 = (5000 + 45000) / 1850 = ~27 ether
        assertApproxEqAbs(twapPrice, 27 ether, 2 ether);
    }

    // =========================================================================
    // 8. ZERO ELAPSED TIME IN PAIR AND ORACLE
    // =========================================================================

    /// @notice Verifies that zero elapsed time between transactions does not corrupt accumulators or allow oracle re-updates
    function test_Adversarial_ZeroElapsedTimeInOracleAndPair() public {
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Calling update again in the same block reverts with PeriodNotElapsed(0, period)
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.PeriodNotElapsed.selector, 0, PERIOD));
        oracle.update();

        // Execute first swap at current timestamp
        token0.mint(alice, 20 ether);
        vm.startPrank(alice);
        token0.transfer(address(pair), 10 ether);
        uint256 out = router.getAmountOut(10 ether, 1_000 ether, 1_000 ether);
        pair.swap(0, out, alice, "");

        // Capture cumulative accumulator after first swap
        uint256 p0AfterFirstSwap = pair.price0CumulativeLast();

        // Immediately execute a SECOND swap in the exact same block / timestamp (timeElapsed == 0)
        (uint112 r0, uint112 r1,) = pair.getReserves();
        token0.transfer(address(pair), 10 ether);
        uint256 out2 = router.getAmountOut(10 ether, r0, r1);
        pair.swap(0, out2, alice, "");
        vm.stopPrank();

        uint256 p0AfterSecondSwap = pair.price0CumulativeLast();
        assertEq(p0AfterFirstSwap, p0AfterSecondSwap, "Cumulative price must not advance on zero elapsed time");
    }

    // =========================================================================
    // 9. UNINITIALIZED ORACLE CANNOT REPORT FALSE AVERAGES
    // =========================================================================

    /// @notice Verifies that an uninitialized oracle reverts on consult rather than reporting zero or default
    function test_Adversarial_UninitializedOracleRevertsOnConsult() public {
        AviorTWAPOracle freshOracle = new AviorTWAPOracle(address(pair), PERIOD);

        // Calling consult before any update reverts with OracleNotInitialized
        vm.expectRevert(AviorTWAPOracle.OracleNotInitialized.selector);
        freshOracle.consult(address(token0), 100 ether);

        vm.expectRevert(AviorTWAPOracle.OracleNotInitialized.selector);
        freshOracle.consult(address(token0), 100 ether, 1 hours);

        vm.expectRevert(AviorTWAPOracle.OracleNotInitialized.selector);
        freshOracle.consultUnchecked(address(token0), 100 ether);
    }

    // =========================================================================
    // 10. DUAL INTERFACE STALENESS ENFORCEMENT & IS_STALE HELPER
    // =========================================================================

    /// @notice Compares consult(token, amount) vs consult(token, amount, maxAge) and consultUnchecked
    function test_Adversarial_DualInterfaceStaleEnforcement() public {
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Immediately after update, age is 0
        assertEq(oracle.observationAge(), 0);
        assertFalse(oracle.isStale(1 hours));

        // All three interfaces return identical quotes when fresh
        uint256 defaultFresh = oracle.consult(address(token0), 100 ether);
        uint256 checkedFresh = oracle.consult(address(token0), 100 ether, 1 hours);
        uint256 uncheckedFresh = oracle.consultUnchecked(address(token0), 100 ether);
        assertEq(defaultFresh, checkedFresh);
        assertEq(defaultFresh, uncheckedFresh);
        assertEq(defaultFresh, 100 ether);

        // Warp 2 hours past update (2 hours > 1 hour maxAge and 2 hours > 2 * PERIOD default)
        vm.warp(block.timestamp + 2 hours);
        assertEq(oracle.observationAge(), 2 hours);
        assertTrue(oracle.isStale(1 hours));

        // 1. The explicit checked interface reverts with StalePrice
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.StalePrice.selector, 2 hours, 1 hours));
        oracle.consult(address(token0), 100 ether, 1 hours);

        // 2. The default consult interface is fail-closed (2 * PERIOD = 1 hour tolerance) and ALSO reverts
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.StalePrice.selector, 2 hours, 2 * PERIOD));
        oracle.consult(address(token0), 100 ether);

        // 3. The unchecked interface returns the stale quote (documenting its integration hazard)
        uint256 uncheckedStale = oracle.consultUnchecked(address(token0), 100 ether);
        assertEq(uncheckedStale, 100 ether);
    }

    // =========================================================================
    // 11. LONG ELAPSED INTERVAL (> 2^32 SECONDS) MODULAR WRAP LIMITATION
    // =========================================================================

    /// @notice Demonstrates the 136-year uint32 wrap limitation: interval >= 2^32 wraps modulo 2^32
    function test_Adversarial_LongElapsedIntervalAnalysis() public {
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Warp 2^32 + 500 seconds into the future (136 years + 500s)
        uint256 hugeTime = block.timestamp + (uint256(1) << 32) + 500;
        vm.warp(hugeTime);

        // Modular distance: (hugeTime % 2^32) - (blockTimestampLast % 2^32) == 500
        // Because 500 < PERIOD (1800), oracle.update() reverts with PeriodNotElapsed(500, 1800)
        vm.expectRevert(abi.encodeWithSelector(AviorTWAPOracle.PeriodNotElapsed.selector, 500, PERIOD));
        oracle.update();
    }

    /// @notice Proves that after 2^32 seconds (~136.19 years), uint32 modular age wraps around,
    ///         causing isStale() and consult(..., maxAge) to misclassify a 136-year-old observation as fresh.
    function test_Adversarial_ObservationAgeWrapsAfter136Years() public {
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Warp 2^32 + 10 seconds into the future
        uint256 ancientTime = block.timestamp + (uint256(1) << 32) + 10;
        vm.warp(ancientTime);

        // Modular distance wraps around: uint32(ancientTime % 2^32) - t0 == 10
        uint32 reportedAge = oracle.observationAge();
        assertEq(reportedAge, 10, "Observation age wrapped modulo 2^32");

        // isStale(3600) evaluates 10 > 3600 -> FALSE!
        assertFalse(oracle.isStale(1 hours), "Ancient observation falsely classified as not stale");

        // consult() with 1 hour maxAge succeeds because 10s < 1 hour!
        uint256 ancientPrice = oracle.consult(address(token0), 100 ether, 1 hours);
        assertEq(ancientPrice, 100 ether, "Ancient 136-year-old observation returned as valid");
    }

    // =========================================================================
    // 12. ROUTER REJECTS FEE-ON-TRANSFER SWAPS WITH INVALID_K
    // =========================================================================

    /// @notice Confirms that standard router swaps of fee-on-transfer tokens fail with InvalidK
    function test_Adversarial_RouterRejectsFeeOnTransferSwap() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Taxed", "TAX", 500, makeAddr("TAX_RECIPIENT"));
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0 = address(fot) < address(standard) ? address(fot) : address(standard);
        address t1 = address(fot) < address(standard) ? address(standard) : address(fot);

        AviorAMMPairSecured fotPair = new AviorAMMPairSecured(t0, t1);
        router.registerPair(address(fot), address(standard), address(fotPair));

        fot.mint(alice, 10_000 ether);
        standard.mint(alice, 10_000 ether);

        vm.startPrank(alice);
        fot.transfer(address(fotPair), 1_900 ether);
        standard.transfer(address(fotPair), 1_900 ether);
        fotPair.mint(alice);
        vm.stopPrank();

        // Bob attempts to swap 100 FoT for standard tokens via router
        fot.mint(bob, 100 ether);
        vm.startPrank(bob);
        fot.approve(address(router), 100 ether);

        address[] memory path = new address[](2);
        path[0] = address(fot);
        path[1] = address(standard);

        // When router transfers 100 FoT, pair only receives 95.
        // Because router calculates amountOut based on 100 in, the pair's K-invariant check fails!
        vm.expectRevert(AviorAMMPairSecured.InvalidK.selector);
        router.swapExactTokensForTokens(100 ether, 1 ether, path, bob, block.timestamp + 100);
        vm.stopPrank();
    }
}
