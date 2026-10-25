// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/DeFiPool.sol";
import "../src/LendingPlatform.sol";
import "../src/ReadOnlyAttack.sol";

contract ReadOnlyTest is Test {
    DeFiPool public pool;
    LendingPlatform public lending;
    ReadOnlyAttack public attacker;

    function setUp() public {
        pool = new DeFiPool();
        lending = new LendingPlatform(address(pool));
        attacker = new ReadOnlyAttack(address(pool), address(lending));

        vm.deal(address(pool), 100 ether);
        vm.deal(address(attacker), 10 ether);
    }

    function testReadOnlyExploit() public {
        attacker.setupAttack{value: 10 ether}();

        attacker.executeExploit();
    }
}
