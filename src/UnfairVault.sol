// SPDX-Licence-Identifier: MIT:
pragma solidity ^0.8.28;

contract UnfairVault {
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public balanceOf;

    function deposit() public payable {
        require(msg.value > 0, "Zero depoit");
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

    function withdraw(uint256 _shares) public {
        require(balanceOf[msg.sender] >= _shares, "Low shares balance");
        uint256 assetsToWithdraw = (_shares * totalAssets);
        balanceOf[msg.sender] -= _shares;
        totalShares -= _shares;
        totalAssets -= assetsToWithdraw;
        (bool success,) = msg.sender.call{value: assetsToWithdraw}("");
        require(success, "Transfer failed");
    }

    function receiveProfit() public payable {
        totalAssets += msg.value;
    }
}
