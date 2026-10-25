// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract SimpleVault {
    mapping(address => uint256) public balances;

    function deposit() public payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 _amount) public {
        require(balances[msg.sender] >= 0, "Not enough funds");
        payable(msg.sender).transfer(_amount);
        unchecked {
            balances[msg.sender] -= _amount;
        }
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
