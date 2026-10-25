// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract TimeVault {
    mapping(address => uint256) private _lockTime;

    function deposit() external payable {
        _lockTime[msg.sender] = block.timestamp + 1 weeks;
    }

    function increaseLockTime(uint256 secondsToWait) external {
        unchecked {
            _lockTime[msg.sender] += secondsToWait;
        }
    }

    function withdraw() external {
        require(block.timestamp >= _lockTime[msg.sender], "Lock time not expired");
        payable(msg.sender).transfer(address(this).balance);
    }
}
