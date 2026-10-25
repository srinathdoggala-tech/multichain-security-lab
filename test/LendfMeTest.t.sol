//SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/LendfMe.sol";
import "../src/LendfMeAttack.sol";

contract LendfMeTest is Test {
    LendfMe public target;
    LendfMeAttack public attackContract;
    address public hacker = address(0x1337);

    function setUp() public {
        target = new LendfMe();
        attackContract = new LendfMeAttack(address(target));
        vm.deal(address(target), 50 ether);
        vm.deal(hacker, 10 ether);
    }

    function testLendfMeExploit() public {
        assertEq(target.balances(address(attackContract)), 0);
        vm.prank(hacker);
        attackContract.attack{value: 10 ether}();
        assertEq(target.balances(address(attackContract)), 10 ether);

        console.log("Stolen credit balance in LendfMe:", target.balances(address(attackContract)));
    }
}
