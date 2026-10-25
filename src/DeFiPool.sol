// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

contract DeFiPool {
    mapping(address => uint256) public liquidity;
    uint256 public totalLiquidity;

    function addLiquidity() external payable {
        liquidity[msg.sender] += msg.value;
        totalLiquidity += msg.value;
    }

    function removeLiquidity(uint256 _amount) external {
        require(liquidity[msg.sender] >= _amount, "Low balance");

        liquidity[msg.sender] -= _amount;

        (bool sent,) = msg.sender.call{value: _amount}("");
        require(sent, "Failed");

        totalLiquidity -= _amount;
    }

    function getVirtualPrice() external view returns (uint256) {
        if (totalLiquidity == 0) return 100;
        return (address(this).balance * 100) / totalLiquidity;
    }
}
