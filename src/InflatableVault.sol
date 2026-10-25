//SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

contract InflatableVault {
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    function deposit() public payable {
        require(msg.value > 0, "Zero deposit");
        uint256 shares;

        if (totalShares == 0) {
            shares = msg.value;
        } else {
            shares = (msg.value * totalShares) / (address(this).balance - msg.value);
        }

        require(shares > 0, "Brave user got 0 shares due to roundig");

        sharesOf[msg.sender] += shares;
        totalShares += shares;
    }

    function withdraw(uint256 _shares) public {
        require(sharesOf[msg.sender] >= _shares, "Low shares balance");
        uint256 ethToWithdraw = (_shares * address(this).balance) / totalShares;

        sharesOf[msg.sender] -= _shares;
        totalShares -= _shares;

        payable(msg.sender).transfer(ethToWithdraw);
    }
    receive() external payable {}
}
