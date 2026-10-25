// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Oracle.sol";

contract Lending {
    Oracle public oracle;
    mapping(address => uint256) public collateral;

    constructor(address _oracle) {
        oracle = Oracle(_oracle);
    }

    function depositCollateral() external payable {
        collateral[msg.sender] += msg.value;
    }

    function borrow() external {
        uint256 price = oracle.price();
        uint256 amountToBorrow = collateral[msg.sender] * price;

        payable(msg.sender).transfer(amountToBorrow);
    }

    receive() external payable {}
}
