// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/Lending.sol";
import "../src/Oracle.sol";

contract OracleAttackTest is Test {
    Lending public lending;
    Oracle public oracle;
    address attacker = address(0x1337);

    function setUp() public {
        oracle = new Oracle(1);

        lending = new Lending(address(oracle));

        vm.deal(address(lending), 100 ether);
    }

    function testOracleExploit() public {
        vm.deal(attacker, 10 ether);
        vm.startPrank(attacker);
        lending.depositCollateral{value: 1 ether}();
        vm.expectRevert("Not owner");
        oracle.setPrice(100);
        lending.borrow();
        vm.stopPrank();
    }
}
