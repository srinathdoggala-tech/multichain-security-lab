// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorRouter.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../mocks/MockERC20.sol";

contract AviorRouterRegressionTest is Test {
    AviorRouter public router;
    AviorAMMPairSecured public pairAB;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenUnregistered;

    address public alice = makeAddr("ALICE");

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenUnregistered = new MockERC20("Unregistered", "UNR", 18);

        (address tA, address tB) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        pairAB = new AviorAMMPairSecured(tA, tB);

        router = new AviorRouter();
        router.registerPair(address(tokenA), address(tokenB), address(pairAB));

        tokenA.mint(address(pairAB), 100 ether);
        tokenB.mint(address(pairAB), 100 ether);
        pairAB.mint(address(this));
    }

    /// @notice Regression 1: Slippage protection — revert when output is below specified minimum
    function test_Regression_SlippageViolationReverts() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        uint256 actualOut = amounts[1];

        // Demand 1 wei more than the pool can mathematically provide
        uint256 unrealisticMin = actualOut + 1;

        tokenA.mint(alice, amountIn);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountIn);
        vm.expectRevert(
            abi.encodeWithSelector(AviorRouter.InsufficientOutputAmount.selector, unrealisticMin, actualOut)
        );
        router.swapExactTokensForTokens(amountIn, unrealisticMin, path, alice, block.timestamp + 100);
        vm.stopPrank();
    }

    /// @notice Regression 2: Expired deadline unconditionally reverts
    function test_Regression_ExpiredDeadlineReverts() public {
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        tokenA.mint(alice, amountIn);

        vm.warp(1000);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountIn);
        // Pass deadline in the past (999 < 1000)
        vm.expectRevert(AviorRouter.ExpiredDeadline.selector);
        router.swapExactTokensForTokens(amountIn, 0, path, alice, 999);
        vm.stopPrank();
    }

    /// @notice Regression 3: Invalid path length (< 2) reverts
    function test_Regression_InvalidPathLengthReverts() public {
        address[] memory singlePath = new address[](1);
        singlePath[0] = address(tokenA);

        vm.expectRevert(AviorRouter.InvalidPathLength.selector);
        router.getAmountsOut(1 ether, singlePath);
    }

    /// @notice Regression 4: Identical consecutive tokens in path reverts
    function test_Regression_IdenticalConsecutiveTokensReverts() public {
        address[] memory circularPath = new address[](2);
        circularPath[0] = address(tokenA);
        circularPath[1] = address(tokenA);

        vm.expectRevert(AviorRouter.IdenticalTokens.selector);
        router.getAmountsOut(1 ether, circularPath);
    }

    /// @notice Regression 5: Unregistered pair reverts with PairNotFound
    function test_Regression_UnregisteredPairReverts() public {
        address[] memory invalidPath = new address[](2);
        invalidPath[0] = address(tokenA);
        invalidPath[1] = address(tokenUnregistered);

        vm.expectRevert(
            abi.encodeWithSelector(AviorRouter.PairNotFound.selector, address(tokenA), address(tokenUnregistered))
        );
        router.getAmountsOut(1 ether, invalidPath);
    }

    /// @notice Regression 6: Zero input amount reverts
    function test_Regression_ZeroAmountInReverts() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.expectRevert(AviorRouter.InsufficientInputAmount.selector);
        router.getAmountsOut(0, path);
    }

    /// @notice Regression 7: Zero address recipient reverts
    function test_Regression_ZeroAddressRecipientReverts() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        tokenA.mint(alice, 1 ether);

        vm.startPrank(alice);
        tokenA.approve(address(router), 1 ether);
        vm.expectRevert(AviorRouter.ZeroAddress.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, address(0), block.timestamp + 100);
        vm.stopPrank();
    }

    /// @notice Fuzz test: Slippage boundary enforcement holds for arbitrary valid swap sizes
    function testFuzz_Router_SlippageEnforcement(uint64 amountInRaw, uint8 slippageBps) public {
        // Bound input from 0.001 ETH to 20 ETH (pool has 100 ETH reserves)
        uint256 amountIn = bound(uint256(amountInRaw), 1e15, 20 ether);
        // Bound allowed slippage tolerance: 0% to 50%
        uint256 tol = bound(uint256(slippageBps), 1, 5000);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        uint256 expectedOut = amounts[1];

        // Minimum acceptable output with tolerance
        uint256 minOut = (expectedOut * (10000 - tol)) / 10000;

        tokenA.mint(alice, amountIn);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountIn);
        uint256[] memory swapAmounts =
            router.swapExactTokensForTokens(amountIn, minOut, path, alice, block.timestamp + 100);
        vm.stopPrank();

        // Router must guarantee actual received >= minOut
        assertTrue(swapAmounts[1] >= minOut, "Slippage bound must strictly hold");
        assertEq(tokenB.balanceOf(alice), swapAmounts[1]);
    }

    /// @notice Regression 8: Attempting swap without sufficient ERC20 allowance reverts
    function test_Regression_InsufficientAllowanceReverts() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        tokenA.mint(alice, 1 ether);

        vm.startPrank(alice);
        // Only approve 0.5 ether but try to swap 1 ether
        tokenA.approve(address(router), 0.5 ether);
        vm.expectRevert();
        router.swapExactTokensForTokens(1 ether, 0, path, alice, block.timestamp + 100);
        vm.stopPrank();
    }

    /// @notice Regression 9: Extreme dust input rounding down to 0 output fails when minOut > 0
    function test_Regression_SmallAmountRoundingEdgeCase() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        // 1 wei input against 100 ETH reserves:
        // numerator = 1 * 997 * 100e18 = 99,700e18
        // denominator = 100e18 * 1000 + 997 = 100,000e18 + 997
        // numerator / denominator rounds down to 0 wei!
        uint256[] memory amounts = router.getAmountsOut(1, path);
        assertEq(amounts[1], 0, "Dust input must round down to 0 output");

        // If minOut requested is 1 wei, router MUST revert with InsufficientOutputAmount(1, 0)
        tokenA.mint(alice, 1);
        vm.startPrank(alice);
        tokenA.approve(address(router), 1);
        vm.expectRevert(abi.encodeWithSelector(AviorRouter.InsufficientOutputAmount.selector, 1, 0));
        router.swapExactTokensForTokens(1, 1, path, alice, block.timestamp + 100);
        vm.stopPrank();
    }
}

