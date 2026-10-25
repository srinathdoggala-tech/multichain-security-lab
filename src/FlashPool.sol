// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract FlashPool {
    uint256 public poolBalance;

    constructor() payable {
        poolBalance = msg.value;
    }

    function flashLoan(uint256 amount, address target, bytes calldata data) external {
        uint256 balanceBefore = address(this).balance;
        require(balanceBefore >= amount, "Not enough funds");

        (bool success,) = target.call{value: amount}(data);
        require(success, "External call failed");

        require(address(this).balance >= balanceBefore, "Flash loan not repaid");
    }

    receive() external payable {}
}
