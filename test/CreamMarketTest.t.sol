// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/CreamMarket.sol";
import "../src/CreamAttack.sol";

contract CreamMarketTest is Test {
    CreamMarket public market;
    CreamAttack public attackContract;
    address public hacker = address(0x1337);

    function setUp() public {
        market = new CreamMarket();
        attackContract = new CreamAttack(address(market));
        vm.deal(address(market), 100 ether);
        vm.deal(hacker, 10 ether);
    }

    function testCreamReentrancy() public {
        assertEq(address(attackContract).balance, 0);
        vm.prank(hacker);
        attackContract.attack{value: 10 ether}();
        assertEq(address(attackContract).balance, 15 ether);
        console.log("Hacker stolen balance:", address(attackContract).balance);
    }
}
