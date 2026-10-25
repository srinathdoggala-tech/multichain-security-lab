// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

import "./GovernanceToken.sol";

interface IFlashLoanReceiver {
    function executeOperation(uint256 amount) external;
}

contract FlashLoanPool {
    GovernanceToken public token;

    constructor(address _tokenAddress) {
        token = GovernanceToken(_tokenAddress);
    }

    function flashLoan(uint256 _amount) public {
        uint256 balanceBefore = token.balanceOf(address(this));
        require(balanceBefore >= _amount, "Not enough tokens in pool");
        require(token.transfer(msg.sender, _amount), "Transfer failed");
        IFlashLoanReceiver(msg.sender).executeOperation(_amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Flash loan not repaid");
    }
}
