// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract AccountingDriftVault {
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        require(msg.value > 0, "Zero deposit");

        uint256 shares;
        if (totalShares == 0) {
            shares = msg.value;
        } else {
            shares = (msg.value * totalShares) / totalAssets;
        }

        require(shares > 0, "Mint zero shares");

        balanceOf[msg.sender] += shares;
        totalShares += shares;
        totalAssets += msg.value;
    }

    function withdraw(uint256 shares) external {
        require(shares > 0, "Zero shares");
        require(balanceOf[msg.sender] >= shares, "Low shares balance");

        totalShares -= shares;
        balanceOf[msg.sender] -= shares;

        uint256 assets = (shares * totalAssets) / totalShares;

        totalAssets -= assets;
        (bool success, ) = msg.sender.call{value: assets}("");
        require(success, "Transfer failed");
    }
}
