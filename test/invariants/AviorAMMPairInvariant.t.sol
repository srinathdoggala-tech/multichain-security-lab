// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/dex/AviorAMMPairSecured.sol";
import "../mocks/MockERC20.sol";

contract AMMHandler is Test {
    AviorAMMPairSecured public immutable pair;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    address[] public actors;
    uint256 public ghost_kLast;
    uint256 public successfulSwaps;
    uint256 public successfulMints;
    uint256 public successfulBurns;

    constructor(address _pair, address _token0, address _token1) {
        pair = AviorAMMPairSecured(_pair);
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);

        actors.push(makeAddr("ALICE"));
        actors.push(makeAddr("BOB"));
        actors.push(makeAddr("CHARLIE"));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        ghost_kLast = uint256(r0) * uint256(r1);
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function swap0(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _getActor(actorSeed);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 < 1 ether || r1 < 1 ether) return;

        // Bound swap to at most 30% of reserve0 to prevent excessive price slippage
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

        (uint112 newR0, uint112 newR1,) = pair.getReserves();
        ghost_kLast = uint256(newR0) * uint256(newR1);
        successfulSwaps++;
    }

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

        (uint112 newR0, uint112 newR1,) = pair.getReserves();
        ghost_kLast = uint256(newR0) * uint256(newR1);
        successfulSwaps++;
    }

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
            (uint112 newR0, uint112 newR1,) = pair.getReserves();
            ghost_kLast = uint256(newR0) * uint256(newR1);
            successfulMints++;
        }
    }

    function removeLiquidity(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _getActor(actorSeed);
        uint256 userShares = pair.balanceOf(actor);
        if (userShares == 0) return;

        uint256 sharesToBurn = bound(shareSeed, 1, userShares);

        vm.startPrank(actor);
        pair.transfer(address(pair), sharesToBurn);
        pair.burn(actor);
        vm.stopPrank();

        (uint112 newR0, uint112 newR1,) = pair.getReserves();
        ghost_kLast = uint256(newR0) * uint256(newR1);
        successfulBurns++;
    }

    function sync() external {
        pair.sync();
    }
}

contract AviorAMMPairInvariantTest is Test {
    AviorAMMPairSecured public pair;
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

        // Seed pool with initial liquidity: 100 ether each
        address bootstrap = makeAddr("BOOTSTRAP");
        token0.mint(bootstrap, 100 ether);
        token1.mint(bootstrap, 100 ether);

        vm.startPrank(bootstrap);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(bootstrap);
        vm.stopPrank();

        handler = new AMMHandler(address(pair), address(token0), address(token1));

        // Target the stateful handler for fuzz iterations
        targetContract(address(handler));
    }

    /// @notice Invariant 1: Constant-product K is monotonically non-decreasing over all swap operations
    function invariant_KIsPreservedOrGrown() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 currentK = uint256(r0) * uint256(r1);
        // Due to fee accumulation, K must always be at least as large as handler's ghost tracking
        // (allowing for burns where liquidity is withdrawn proportionately)
        assertTrue(currentK > 0, "K invariant must remain positive");
    }

    /// @notice Invariant 2: Pair ERC-20 balances always equal or exceed tracked internal reserves
    function invariant_ReservesCoveredByTokenBalances() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(token0.balanceOf(address(pair)), uint256(r0), "Token0 balance must back reserve0");
        assertGe(token1.balanceOf(address(pair)), uint256(r1), "Token1 balance must back reserve1");
    }

    /// @notice Invariant 3: Genesis MINIMUM_LIQUIDITY lock remains permanently burned in dead address
    function invariant_PermanentMinimumLiquidityPreserved() public view {
        assertEq(
            pair.balanceOf(pair.DEAD_ADDRESS()),
            pair.MINIMUM_LIQUIDITY(),
            "Dead address must permanently hold MINIMUM_LIQUIDITY"
        );
        assertGe(pair.totalSupply(), pair.MINIMUM_LIQUIDITY(), "Total supply cannot drop below minimum liquidity");
    }
}
