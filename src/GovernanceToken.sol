// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract GovernanceToken {
    string public name = "Governance Token";
    string public symbol = "GOV";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    constructor(uint256 _initialSupply) {
        totalSupply = _initialSupply;
        balanceOf[msg.sender] = _initialSupply;
    }

    function transfer(address _to, uint256 _value) public returns (bool success) {
        require(balanceOf[msg.sender] >= _value, "Low balance");
        balanceOf[msg.sender] -= _value;
        balanceOf[_to] += _value;
        return true;
    }
}
