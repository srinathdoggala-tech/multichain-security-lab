// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./FlashPool.sol";

contract VulnerableVault {
    FlashPool public pool;
    mapping(address => uint256) public rewards;

    constructor(address payable _pool) {
        pool = FlashPool(_pool);
    }

    function claimReward() external {
        uint256 poolBalance = address(pool).balance;

        if (poolBalance > 10 ether) {
            rewards[msg.sender] += 1;
        }
    }
}
