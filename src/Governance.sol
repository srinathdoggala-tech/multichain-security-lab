// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract Governance {
    uint256 public yesVotes;
    address public tokenAddress;

    constructor(address _token) {
        tokenAddress = _token;
    }

    function vote() public {
        uint256 balance = IERC20(tokenAddress).balanceOf(msg.sender);
        yesVotes += balance;
    }
}
