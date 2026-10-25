// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract CreamMarket {
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    function depositCollateral() public payable {
        collateralOf[msg.sender] += msg.value;
    }

    function borrow(uint256 _amount) public {
        require(collateralOf[msg.sender] >= _amount * 2, "Not enough collateral");
        (bool success,) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        debtOf[msg.sender] += _amount;
    }

    function withdrawCollateral(uint256 _amount) public {
        require(collateralOf[msg.sender] >= _amount, "Low collateral balance");
        require(collateralOf[msg.sender] - _amount >= debtOf[msg.sender] * 2, "Collateral protects debt");
        collateralOf[msg.sender] -= _amount;
        (bool success,) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
    }
}
