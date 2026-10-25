//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract VulnerableShares {
    mapping(address => uint256) public shareBalance;
    uint256 public totalShares;
    uint256 public totalAssets;

    function deposit() external payable {
        require(msg.value > 0, "Zero amount");
        uint256 sharesToMint;

        if (totalShares == 0) {
            sharesToMint = msg.value;
        } else {
            sharesToMint = (msg.value * totalShares) / totalAssets;
        }
        require(sharesToMint > 0, "Zero shares minted");

        shareBalance[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalAssets += msg.value;
    }

    function withdraw(uint256 shares) external {
        require(shares > 0, "Zero shares");
        require(shareBalance[msg.sender] >= shares, "Insufficient shares");

        uint256 assetsToReturn = (shares * totalAssets) / totalShares;

        shareBalance[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assetsToReturn;
        payable(msg.sender).transfer(assetsToReturn);
    }
    receive() external payable {}
}
