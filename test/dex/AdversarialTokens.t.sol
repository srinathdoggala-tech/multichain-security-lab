// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../../src/dex/AviorRouter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/FeeOnTransferToken.sol";
import "../mocks/RebasingToken.sol";
import "../mocks/MissingReturnToken.sol";
import "../mocks/ReentrantHookToken.sol";

/// @notice Helper attacker contract to test reentrancy hooks against AMM and Router
contract ReentrancyExploiter is ITokenHookReceiver {
    AviorAMMPairSecured public pair;
    AviorRouter public router;
    bool public reenterAttempted;
    bool public reenterSucceeded;
    bytes4 public targetAction;

    constructor(address _pair, address _router) {
        pair = AviorAMMPairSecured(_pair);
        router = AviorRouter(_router);
    }

    function setTargetAction(bytes4 action) external {
        targetAction = action;
        reenterAttempted = false;
        reenterSucceeded = false;
    }

    function onTokenHook(address, address, uint256) external override {
        if (!reenterAttempted) {
            reenterAttempted = true;
            if (targetAction == bytes4(keccak256("swap(uint256,uint256,address,bytes)"))) {
                try pair.swap(0, 1 ether, address(this), "") {
                    reenterSucceeded = true;
                } catch {}
            } else if (targetAction == bytes4(keccak256("mint(address)"))) {
                try pair.mint(address(this)) {
                    reenterSucceeded = true;
                } catch {}
            } else if (targetAction == bytes4(keccak256("sync()"))) {
                try pair.sync() {
                    reenterSucceeded = true;
                } catch {}
            } else if (targetAction == bytes4(keccak256("skim(address)"))) {
                try pair.skim(address(this)) {
                    reenterSucceeded = true;
                } catch {}
            }
        }
    }
}

contract AdversarialTokensTest is Test {
    AviorRouter public router;
    address public alice = address(0xA11CE);
    address public attacker = address(0xBAD);

    function setUp() public {
        router = new AviorRouter();
    }

    // =========================================================================
    // 1. FEE-ON-TRANSFER (FoT) TOKEN TESTS
    // =========================================================================

    function test_Adversarial_FeeOnTransferDirectSwapMeasuresActualDelta() public {
        // Deploy FoT token with 5% fee (500 bps) sent to fee recipient
        address feeRecipient = address(0xFEE);
        FeeOnTransferToken fot = new FeeOnTransferToken("Tax Token", "TAX", 500, feeRecipient);
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0;
        address t1;
        if (address(fot) < address(standard)) {
            t0 = address(fot);
            t1 = address(standard);
        } else {
            t0 = address(standard);
            t1 = address(fot);
        }

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);

        // Seed liquidity: 10,000 each (taking into account fee on fot)
        fot.mint(alice, 20_000 ether);
        standard.mint(alice, 20_000 ether);

        vm.startPrank(alice);
        // Transfer into pair directly
        fot.transfer(address(pair), 10_000 ether); // Pair receives 9,500 due to 5% fee
        standard.transfer(address(pair), 10_000 ether);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (t0 == address(fot)) {
            assertEq(r0, 9_500 ether);
            assertEq(r1, 10_000 ether);
        } else {
            assertEq(r0, 10_000 ether);
            assertEq(r1, 9_500 ether);
        }

        // Now user swaps 100 fot tokens
        fot.mint(alice, 100 ether);
        vm.startPrank(alice);
        fot.transfer(address(pair), 100 ether); // Pair receives 95 ether!

        // If pair calculates amountOut based on actual 95 ether input, swap succeeds!
        uint256 amountOut;
        if (t0 == address(fot)) {
            amountOut = router.getAmountOut(95 ether, r0, r1);
            pair.swap(0, amountOut, alice, "");
        } else {
            amountOut = router.getAmountOut(95 ether, r1, r0);
            pair.swap(amountOut, 0, alice, "");
        }
        vm.stopPrank();

        assertGt(amountOut, 0);
    }

    function test_Adversarial_FeeOnTransferRouterSwapNaiveReverts() public {
        address feeRecipient = address(0xFEE);
        FeeOnTransferToken fot = new FeeOnTransferToken("Tax Token", "TAX", 500, feeRecipient);
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0;
        address t1;
        if (address(fot) < address(standard)) {
            t0 = address(fot);
            t1 = address(standard);
        } else {
            t0 = address(standard);
            t1 = address(fot);
        }

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);
        router.registerPair(address(fot), address(standard), address(pair));

        fot.mint(alice, 50_000 ether);
        standard.mint(alice, 50_000 ether);

        vm.startPrank(alice);
        fot.transfer(address(pair), 10_000 ether);
        standard.transfer(address(pair), 10_000 ether);
        pair.mint(alice);

        // User attempts naive router swap expecting 100 ether to arrive
        fot.approve(address(router), 100 ether);
        address[] memory path = new address[](2);
        path[0] = address(fot);
        path[1] = address(standard);

        // Router assumes pair receives full 100 ether, but pair only receives 95 ether.
        // Pair's _validateK reverts with InvalidK()!
        vm.expectRevert(AviorAMMPairSecured.InvalidK.selector);
        router.swapExactTokensForTokens(100 ether, 1, path, alice, block.timestamp + 100);
        vm.stopPrank();
    }

    // =========================================================================
    // 2. REBASING TOKEN TESTS (POSITIVE & NEGATIVE SUPPLY ELASTICITY)
    // =========================================================================

    function test_Adversarial_PositiveRebaseEnablesSkimTheft() public {
        // Deploy rebasing token with 10,000 initial supply
        RebasingToken rebaseToken = new RebasingToken("Elastic Token", "ELAST", 10_000 ether);
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

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);

        // Alice deposits 1,000 rebasing tokens and 1,000 standard tokens
        rebaseToken.mint(alice, 5_000 ether);
        standard.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        rebaseToken.transfer(address(pair), 1_000 ether);
        standard.transfer(address(pair), 1_000 ether);
        uint256 lpShares = pair.mint(alice);
        vm.stopPrank();

        assertGt(lpShares, 0);

        // Positive rebase: Supply expands by 20% (15,000 -> 18,000)
        uint256 currentSupply = rebaseToken.totalSupply();
        rebaseToken.rebase((currentSupply * 120) / 100);

        // Pair's physical balance expanded from 1,000 ether to 1,200 ether
        assertEq(rebaseToken.balanceOf(address(pair)), 1_200 ether);

        // Reserves still record 1,000 ether:
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint112 recordedRebaseReserve = t0 == address(rebaseToken) ? r0 : r1;
        assertEq(recordedRebaseReserve, 1_000 ether);

        // Attacker calls skim(attacker) and extracts the 200 excess tokens without paying any LP shares!
        vm.prank(attacker);
        pair.skim(attacker);

        assertApproxEqAbs(rebaseToken.balanceOf(attacker), 200 ether, 1);
        assertApproxEqAbs(rebaseToken.balanceOf(address(pair)), 1_000 ether, 1);
    }

    function test_Adversarial_NegativeRebaseForcedSyncDropsReserves() public {
        RebasingToken rebaseToken = new RebasingToken("Elastic Token", "ELAST", 10_000 ether);
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

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);

        rebaseToken.mint(alice, 5_000 ether);
        standard.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        rebaseToken.transfer(address(pair), 1_000 ether);
        standard.transfer(address(pair), 1_000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Negative rebase: Supply contracts by 20%
        uint256 currentSupply = rebaseToken.totalSupply();
        rebaseToken.rebase((currentSupply * 80) / 100);

        // Pair's physical balance contracted to 800 ether
        assertEq(rebaseToken.balanceOf(address(pair)), 800 ether);

        // Calling sync updates reserves down to actual contracted balance
        pair.sync();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint112 newRebaseReserve = t0 == address(rebaseToken) ? r0 : r1;
        assertEq(newRebaseReserve, 800 ether);
    }

    // =========================================================================
    // 3. MISSING RETURN VALUE TOKEN (USDT-STYLE NON-STANDARD ERC-20)
    // =========================================================================

    function test_Adversarial_MissingReturnSupportedBySafeTransfer() public {
        MissingReturnToken usdt = new MissingReturnToken(1_000_000 * 1e6);
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0;
        address t1;
        if (address(usdt) < address(standard)) {
            t0 = address(usdt);
            t1 = address(standard);
        } else {
            t0 = address(standard);
            t1 = address(usdt);
        }

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);
        router.registerPair(address(usdt), address(standard), address(pair));

        // Router uses SafeERC20 which handles tokens with no return value
        usdt.mint(alice, 10_000 * 1e6);
        standard.mint(alice, 10_000 ether);

        vm.startPrank(alice);
        usdt.approve(address(router), 5_000 * 1e6);
        standard.approve(address(router), 5_000 ether);

        // Add liquidity succeeds seamlessly with SafeERC20
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(usdt), address(standard), 5_000 * 1e6, 5_000 ether, 1, 1, alice, block.timestamp + 100
        );

        assertGt(liquidity, 0);
        assertEq(amountA, 5_000 * 1e6);
        assertEq(amountB, 5_000 ether);
        vm.stopPrank();
    }

    // =========================================================================
    // 4. REENTRANT HOOK TOKEN (ERC-777 / ERC-1363 CALLBACK REENTRANCY)
    // =========================================================================

    function test_Adversarial_ReentrantHookBlockedByNonReentrant() public {
        ReentrantHookToken hookToken = new ReentrantHookToken("Hook Token", "HOOK");
        MockERC20 standard = new MockERC20("Standard", "STD", 18);

        address t0;
        address t1;
        if (address(hookToken) < address(standard)) {
            t0 = address(hookToken);
            t1 = address(standard);
        } else {
            t0 = address(standard);
            t1 = address(hookToken);
        }

        AviorAMMPairSecured pair = new AviorAMMPairSecured(t0, t1);
        ReentrancyExploiter exploiter = new ReentrancyExploiter(address(pair), address(router));

        // Seed liquidity
        hookToken.mint(alice, 10_000 ether);
        standard.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        hookToken.transfer(address(pair), 5_000 ether);
        standard.transfer(address(pair), 5_000 ether);
        pair.mint(alice);
        vm.stopPrank();

        // Configure hook on exploiter contract to reenter swap during token transfer
        hookToken.setHook(address(exploiter), true);
        exploiter.setTargetAction(bytes4(keccak256("swap(uint256,uint256,address,bytes)")));

        // Give exploiter tokens and try to execute swap which triggers hook
        hookToken.mint(address(exploiter), 100 ether);

        vm.startPrank(address(exploiter));
        hookToken.transfer(address(pair), 100 ether);

        // Attempting swap which triggers reentrant callback in onTokenHook
        if (t0 == address(hookToken)) {
            pair.swap(0, 10 ether, address(exploiter), "");
        } else {
            pair.swap(10 ether, 0, address(exploiter), "");
        }
        vm.stopPrank();

        // The reentrant call was attempted, but failed because nonReentrant blocked it!
        assertTrue(exploiter.reenterAttempted());
        assertFalse(exploiter.reenterSucceeded());
    }
}
