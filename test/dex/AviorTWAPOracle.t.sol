// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/AviorTWAPOracle.sol";
import "../../src/dex/AviorRouter.sol";
import "../mocks/MockERC20.sol";

contract AviorTWAPOracleTest is Test {
    AviorAMMPairSecured public pair;
    AviorTWAPOracle public oracle;
    AviorRouter public router;

    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public token0;
    address public token1;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public attacker = address(0xBAD);

    uint256 public constant PERIOD = 1800; // 30 minutes

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // Ensure token0 < token1 ordering
        if (address(tokenA) < address(tokenB)) {
            token0 = address(tokenA);
            token1 = address(tokenB);
        } else {
            token0 = address(tokenB);
            token1 = address(tokenA);
        }

        pair = new AviorAMMPairSecured(token0, token1);
        router = new AviorRouter();

        // Mint initial liquidity: 1,000 of token0 and 1,000 of token1 (1:1 spot ratio)
        MockERC20(token0).mint(alice, 100_000 ether);
        MockERC20(token1).mint(alice, 100_000 ether);

        vm.startPrank(alice);
        MockERC20(token0).transfer(address(pair), 1_000 ether);
        MockERC20(token1).transfer(address(pair), 1_000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Warp time slightly after genesis mint
        vm.warp(block.timestamp + 10);

        // Deploy TWAP Oracle with 30-minute window
        oracle = new AviorTWAPOracle(address(pair), PERIOD);
    }

    function test_TWAP_InitialState() public view {
        assertEq(oracle.token0(), token0);
        assertEq(oracle.token1(), token1);
        assertEq(oracle.period(), PERIOD);
        assertEq(oracle.price0Average(), 0);
        assertEq(oracle.price1Average(), 0);
    }

    function test_TWAP_RevertIfPeriodNotElapsed() public {
        // Attempt update with zero time elapsed
        vm.expectRevert();
        oracle.update();

        // Advance only 1,000 seconds (< 1,800 seconds)
        vm.warp(block.timestamp + 1000);
        vm.expectRevert();
        oracle.update();
    }

    function test_TWAP_UpdateComputesAccurateAverage() public {
        // Advance time by full 1,800 second period
        vm.warp(block.timestamp + PERIOD);

        oracle.update();

        // At 1:1 reserve ratio, price is 1.0 (in UQ112x112, 1.0 == 2^112)
        uint224 expectedOne = uint224(1) << 112;
        assertEq(oracle.price0Average(), expectedOne);
        assertEq(oracle.price1Average(), expectedOne);

        // Consult 100 ether of token0 -> should yield exactly 100 ether of token1
        uint256 amountOut1 = oracle.consult(token0, 100 ether);
        assertEq(amountOut1, 100 ether);

        // Consult 250 ether of token1 -> should yield exactly 250 ether of token0
        uint256 amountOut0 = oracle.consult(token1, 250 ether);
        assertEq(amountOut0, 250 ether);
    }

    function test_TWAP_SingleBlockFlashLoanDoesNotManipulateOracle() public {
        // 1. Establish valid baseline TWAP at 1:1 price
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        assertEq(oracle.consult(token0, 100 ether), 100 ether);

        // 2. Attacker executes massive flash swap manipulation within a single block
        MockERC20(token0).mint(attacker, 50_000 ether);
        vm.startPrank(attacker);

        // Attacker dumps 9,000 token0 into the pool (increasing reserve0 10x)
        MockERC20(token0).transfer(address(pair), 9_000 ether);
        uint256 amount1Out = router.getAmountOut(9_000 ether, 1_000 ether, 1_000 ether);
        pair.swap(0, amount1Out, attacker, "");
        vm.stopPrank();

        // 3. Inspect instantaneous spot price vs TWAP price
        uint256 manipulatedSpotPrice = oracle.consultSpot(token0, 100 ether);
        uint256 resistantTWAPPrice = oracle.consult(token0, 100 ether);

        // Instantaneous spot output crashed drastically from 100 ether down to ~1 ether
        assertLt(manipulatedSpotPrice, 2 ether);

        // TWAP price is completely unmanipulated and remains 100 ether!
        assertEq(resistantTWAPPrice, 100 ether);

        // 4. If attacker tries to force an oracle update in the same block, it strictly reverts
        vm.expectRevert();
        oracle.update();
    }

    function test_TWAP_MultiPeriodWeightedAverageAccurate() public {
        // Period 1: 1,800 seconds at 1:1 ratio
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // Swap to change price: add 1,000 token0 to pool so reserves are 2,000 token0 and ~500 token1 (ratio 1:4)
        MockERC20(token0).mint(bob, 1_000 ether);
        vm.startPrank(bob);
        MockERC20(token0).transfer(address(pair), 1_000 ether);
        // 1000 * 1000 = 1,000,000. New reserve0 = 2000 => new reserve1 = 500 => amountOut = 500 ether (approx with fee)
        pair.swap(0, 498 ether, bob, "");
        vm.stopPrank();

        // Period 2: Hold the new skewed price for exactly PERIOD (1,800 seconds)
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        // TWAP now accurately reflects the new period average
        uint256 amountOut = oracle.consult(token0, 100 ether);
        // At ~2000 token0 to ~502 token1, price is ~0.25 token1 per token0
        assertApproxEqAbs(amountOut, 25 ether, 1 ether);
    }

    function test_TWAP_InvalidTokenReverts() public {
        vm.warp(block.timestamp + PERIOD);
        oracle.update();

        address bogusToken = address(0xDEADBEEF);
        vm.expectRevert(AviorTWAPOracle.InvalidToken.selector);
        oracle.consult(bogusToken, 100 ether);

        vm.expectRevert(AviorTWAPOracle.InvalidToken.selector);
        oracle.consultSpot(bogusToken, 100 ether);
    }
}
