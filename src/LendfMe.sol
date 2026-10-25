// SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.28;

contract LendfMe {
    mapping(address => uint256) public balances;

    function deposit(uint256 _amount) public {
        (bool success,) = msg.sender.call{value: 0}("");
        require(success, "Callback failed");
        balances[msg.sender] += _amount;
    }

    function withdraw(uint256 _amount) public {
        balances[msg.sender] -= _amount;
        payable(msg.sender).transfer(_amount);
    }
}
