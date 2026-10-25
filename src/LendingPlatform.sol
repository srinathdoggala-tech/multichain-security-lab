// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./DeFiPool.sol";

contract LendingPlatform {
    DeFiPool public pool;

    constructor(address _pool) {
        pool = DeFiPool(_pool);
    }

    function checkCollateralValue() external view returns (uint256) {
        uint256 price = pool.getVirtualPrice();
        return price;
    }
}
