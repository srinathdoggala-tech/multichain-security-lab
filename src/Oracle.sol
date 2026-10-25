// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Oracle {
    address public owner;
    uint256 public price;

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        price = initialPrice;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
    }
}
