// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorRouter.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../mocks/MockERC20.sol";

contract AviorRouterTest is Test {
    AviorRouter public router;
    AviorAMMPairSecured public pairAB;
    AviorAMMPairSecured public pairBC;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    address public alice = makeAddr("ALICE");
    address public bob = makeAddr("BOB");

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);

        // Sort tokens for canonical pair setup
        (address tA, address tB) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        (address tB2, address tC) =
            address(tokenB) < address(tokenC) ? (address(tokenB), address(tokenC)) : (address(tokenC), address(tokenB));

        pairAB = new AviorAMMPairSecured(tA, tB);
        pairBC = new AviorAMMPairSecured(tB2, tC);

        router = new AviorRouter();
        router.registerPair(address(tokenA), address(tokenB), address(pairAB));
        router.registerPair(address(tokenB), address(tokenC), address(pairBC));

        // Bootstrap liquidity in pairAB: 100 TKNA and 200 TKNB (Price: 1 TKNA = 2 TKNB)
        tokenA.mint(address(pairAB), 100 ether);
        tokenB.mint(address(pairAB), 200 ether);
        pairAB.mint(address(this));

        // Bootstrap liquidity in pairBC: 200 TKNB and 200 TKNC (Price: 1 TKNB = 1 TKNC)
        tokenB.mint(address(pairBC), 200 ether);
        tokenC.mint(address(pairBC), 200 ether);
        pairBC.mint(address(this));
    }

    /// @notice Test 1: Router quote calculation matches proportion
    function test_Router_Quote() public view {
        uint256 quoteOut = router.quote(10 ether, 100 ether, 200 ether);
        assertEq(quoteOut, 20 ether);
    }

    /// @notice Test 2: Single-hop getAmountOut applies 0.3% fee correctly
    function test_Router_GetAmountOutSingleHop() public view {
        (uint112 rA, uint112 rB,) = pairAB.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = address(tokenA) == pairAB.token0() ? (rA, rB) : (rB, rA);

        uint256 amountIn = 1 ether;
        uint256 expectedOut = router.getAmountOut(amountIn, reserveIn, reserveOut);

        // Manual check: (1e18 * 997 * 200e18) / (100e18 * 1000 + 1e18 * 997)
        uint256 manual = (uint256(1 ether) * 997 * 200 ether) / (uint256(100 ether) * 1000 + uint256(1 ether) * 997);
        assertEq(expectedOut, manual);
        assertTrue(expectedOut > 0 && expectedOut < 2 ether);
    }

    /// @notice Test 3: Normal successful single-hop swap via router
    function test_Router_SuccessfulSingleHopSwap() public {
        uint256 amountIn = 5 ether;
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedOut = expectedAmounts[1];

        tokenA.mint(alice, amountIn);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            expectedOut, // Exact min output required
            path,
            alice,
            block.timestamp + 100
        );
        vm.stopPrank();

        assertEq(amounts[1], expectedOut);
        assertEq(tokenB.balanceOf(alice), expectedOut);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    /// @notice Test 4: Multi-hop routing across two pairs (tokenA -> tokenB -> tokenC)
    function test_Router_SuccessfulMultiHopSwap() public {
        uint256 amountIn = 2 ether;
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256[] memory expectedAmounts = router.getAmountsOut(amountIn, path);
        uint256 expectedFinalOut = expectedAmounts[2];

        tokenA.mint(alice, amountIn);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            expectedFinalOut,
            path,
            bob, // deliver to Bob
            block.timestamp + 60
        );
        vm.stopPrank();

        assertEq(amounts[2], expectedFinalOut);
        assertEq(tokenC.balanceOf(bob), expectedFinalOut);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    /// @notice Test 5: Router addLiquidity transfers optimal amounts and mints LP tokens
    function test_Router_AddLiquidityOptimal() public {
        tokenA.mint(alice, 10 ether);
        tokenB.mint(alice, 25 ether);

        vm.startPrank(alice);
        tokenA.approve(address(router), 10 ether);
        tokenB.approve(address(router), 25 ether);

        // At 100 : 200 ratio, 10 tokenA requires 20 tokenB
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 25 ether, 10 ether, 20 ether, alice, block.timestamp + 100
        );
        vm.stopPrank();

        assertEq(amountA, 10 ether);
        assertEq(amountB, 20 ether);
        assertGt(liquidity, 0);
        assertEq(pairAB.balanceOf(alice), liquidity);
        // Alice should retain the leftover 5 tokenB
        assertEq(tokenB.balanceOf(alice), 5 ether);
    }

    /// @notice Test 6: Router removeLiquidity burns LP tokens and returns underlying assets
    function test_Router_RemoveLiquidity() public {
        tokenA.mint(alice, 10 ether);
        tokenB.mint(alice, 20 ether);

        vm.startPrank(alice);
        tokenA.approve(address(router), 10 ether);
        tokenB.approve(address(router), 20 ether);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 10 ether, 20 ether, 10 ether, 20 ether, alice, block.timestamp + 100
        );

        // Approve router for LP tokens and remove liquidity
        pairAB.approve(address(router), liquidity);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, 9 ether, 19 ether, alice, block.timestamp + 100
        );
        vm.stopPrank();

        assertGe(amountA, 9 ether);
        assertGe(amountB, 19 ether);
        assertEq(pairAB.balanceOf(alice), 0);
    }
}
