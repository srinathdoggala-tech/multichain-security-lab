// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/Vault.sol";

contract VaultTest is Test {
    Vault public vault;
    address attacker = address(0x1337);

    function setUp() public {
        vault = new Vault();
    }

    function testExploitAccessControl() public {
        assertEq(vault.owner(), address(this));

        vm.prank(attacker);
        vm.expectRevert(Vault.NotOwner.selector);
        vault.changeOwner(attacker);
        assertEq(vault.owner(), address(this));

        console.log("New owner is attacker:", vault.owner());
    }
}
