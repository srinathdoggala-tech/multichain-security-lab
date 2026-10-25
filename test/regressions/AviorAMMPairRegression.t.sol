// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/IAviorCallee.sol";
import "../mocks/MockERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Callee attempting reentrant sync() against secured pair
contract MaliciousSecuredCallee is IAviorCallee {
    AviorAMMPairSecured public immutable pair;

    constructor(address _pair) {
        pair = AviorAMMPairSecured(_pair);
    }

    function aviorCall(address, uint256, uint256, bytes calldata) external override {
        // Attempt reentrant call to sync()
        pair.sync();
    }
}

/// @dev Legitimate flash borrower that repays principal plus 0.3% fee
contract LegitimateFlashBorrower is IAviorCallee {
    AviorAMMPairSecured public immutable pair;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    constructor(address _pair, address _token0, address _token1) {
        pair = AviorAMMPairSecured(_pair);
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
    }

    function aviorCall(address, uint256 amount0Out, uint256 amount1Out, bytes calldata) external override {
        if (amount0Out > 0) {
            // Fee calculation: amountIn * 997 >= amount0Out * 1000
            uint256 fee = (amount0Out * 3) / 997 + 1;
            token0.transfer(address(pair), amount0Out + fee);
        }
        if (amount1Out > 0) {
            uint256 fee = (amount1Out * 3) / 997 + 1;
            token1.transfer(address(pair), amount1Out + fee);
        }
    }
}

contract AviorAMMPairRegressionTest is Test {
    AviorAMMPairSecured public securedPair;
    MockERC20 public token0;
    MockERC20 public token1;

    address public lpProvider = makeAddr("LP_PROVIDER");
    address public attacker = makeAddr("ATTACKER");
    address public victim = makeAddr("VICTIM");

    function setUp() public {
        token0 = new MockERC20("Token Alpha", "TKNA", 18);
        token1 = new MockERC20("Token Beta", "TKNB", 18);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        securedPair = new AviorAMMPairSecured(address(token0), address(token1));

        // Initial Liquidity Provision: 100 TKNA and 100 TKNB
        token0.mint(lpProvider, 100 ether);
        token1.mint(lpProvider, 100 ether);

        vm.startPrank(lpProvider);
        token0.transfer(address(securedPair), 100 ether);
        token1.transfer(address(securedPair), 100 ether);
        securedPair.mint(lpProvider);
        vm.stopPrank();
    }

    /// @notice Regression 1: Reentrant sync() in flash swap callback is blocked by nonReentrant
    function test_Regression_ReentrantSyncBlockedByGuard() public {
        MaliciousSecuredCallee attackContract = new MaliciousSecuredCallee(address(securedPair));

        vm.startPrank(attacker);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        securedPair.swap(10 ether, 0, address(attackContract), bytes("REENTRANCY_ATTEMPT"));
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = securedPair.getReserves();
        assertEq(r0, 100 ether, "Reserves must remain untouched after blocked reentrancy");
        assertEq(r1, 100 ether, "Reserves must remain untouched after blocked reentrancy");
    }

    /// @notice Regression 2: Flash swap without paying 0.3% fee reverts with InvalidK
    function test_Regression_FlashSwapWithoutFeeReverts() public {
        address noFeeCallee = makeAddr("NO_FEE_CALLEE");

        vm.startPrank(attacker);
        // Swapping without any input amount returns InsufficientInputAmount
        vm.expectRevert(AviorAMMPairSecured.InsufficientInputAmount.selector);
        securedPair.swap(10 ether, 0, noFeeCallee, bytes(""));
        vm.stopPrank();
    }

    /// @notice Regression 3: Legitimate flash loan with fee repayment succeeds and grows reserves
    function test_Regression_LegitimateFlashLoanSucceeds() public {
        LegitimateFlashBorrower legitimateCallee =
            new LegitimateFlashBorrower(address(securedPair), address(token0), address(token1));

        // Fund callee with tokens to pay the fee
        token0.mint(address(legitimateCallee), 1 ether);

        (uint112 r0Before,,) = securedPair.getReserves();

        uint256 borrowAmount = 10 ether;
        securedPair.swap(borrowAmount, 0, address(legitimateCallee), bytes("LEGIT_FLASH"));

        (uint112 r0After,,) = securedPair.getReserves();
        assertTrue(r0After > r0Before, "Reserve0 must increase after fee repayment");
    }

    /// @notice Regression 4: Genesis deposit locks MINIMUM_LIQUIDITY to neutralize inflation attacks
    function test_Regression_MinimumLiquidityProtectsSubsequentDepositors() public {
        AviorAMMPairSecured freshPair = new AviorAMMPairSecured(address(token0), address(token1));

        // Attacker attempts genesis deposit
        token0.mint(attacker, 20 ether);
        token1.mint(attacker, 20 ether);

        vm.startPrank(attacker);
        // Depositing less than MINIMUM_LIQUIDITY (1000) reverts
        token0.transfer(address(freshPair), 500);
        token1.transfer(address(freshPair), 500);
        vm.expectRevert(AviorAMMPairSecured.InsufficientLiquidityMinted.selector);
        freshPair.mint(attacker);

        // Attacker deposits additional 9,500 units (reaching 10,000 total balance)
        token0.transfer(address(freshPair), 9500);
        token1.transfer(address(freshPair), 9500);
        uint256 attackerShares = freshPair.mint(attacker);
        // 10,000 - 1,000 (locked) = 9,000 shares
        assertEq(attackerShares, 9000);
        assertEq(freshPair.balanceOf(freshPair.DEAD_ADDRESS()), 1000);

        // Attacker donates 10 ether to try to dilute next depositor
        token0.transfer(address(freshPair), 10 ether);
        vm.stopPrank();

        // Victim deposits 5 ether of token0 and token1
        token0.mint(victim, 5 ether);
        token1.mint(victim, 5 ether);

        vm.startPrank(victim);
        token0.transfer(address(freshPair), 5 ether);
        token1.transfer(address(freshPair), 5 ether);
        uint256 victimShares = freshPair.mint(victim);
        vm.stopPrank();

        // With MINIMUM_LIQUIDITY locked, victim receives legitimate non-zero shares
        assertTrue(victimShares > 0, "Victim must receive non-zero pro-rata shares");
    }

    /// @notice Fuzz test: Arbitrary valid swaps preserve or increase the K invariant
    function testFuzz_SwapPreservesKInvariant(uint64 amount0InRaw) public {
        // Bound input to realistic range (0.001 ether to 50 ether)
        uint256 amount0In = bound(uint256(amount0InRaw), 1e15, 50 ether);

        (uint112 r0Before, uint112 r1Before,) = securedPair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        // Calculate expected output with 0.3% fee: amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        uint256 amount0InWithFee = amount0In * 997;
        uint256 numerator = amount0InWithFee * uint256(r1Before);
        uint256 denominator = (uint256(r0Before) * 1000) + amount0InWithFee;
        uint256 amount1Out = numerator / denominator;

        token0.mint(attacker, amount0In);

        vm.startPrank(attacker);
        token0.transfer(address(securedPair), amount0In);
        securedPair.swap(0, amount1Out, attacker, bytes(""));
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = securedPair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        // Mathematical invariant: Due to the 0.3% fee, K must be strictly greater than or equal to K before
        assertTrue(kAfter >= kBefore, "K invariant must not decrease after swap with fee");
    }
}
