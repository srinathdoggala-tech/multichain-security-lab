//SPDX-License-Identifier:MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/VulnerableShares.sol";

contract VaultHandler is Test {
    VulnerableShares public vault;
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address private currentActor;

    constructor(VulnerableShares _vault) {
        vault = _vault;
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    function deposit(uint256 amount, uint8 userIndex) external {
        currentActor = userIndex % 2 == 0 ? user1 : user2;
        amount = bound(amount, 1 wei, currentActor.balance);

        if (amount > 0) {
            vm.prank(currentActor);
            vault.deposit{value: amount}();
        }
    }

    function withdraw(uint256 shares, uint8 userIndex) external {
        currentActor = userIndex % 2 == 0 ? user1 : user2;
        uint256 userShares = vault.shareBalance(currentActor);
        shares = bound(shares, 0, userShares);

        if (shares > 0) {
            vm.prank(currentActor);
            vault.withdraw(shares);
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1 wei, 1 ether);

        vm.deal(address(this), amount);

        (bool success,) = address(vault).call{value: amount}("");
        require(success, "Transfer failed");
    }
}

contract VulnerableSharesTest is Test {
    VulnerableShares public vault;
    VaultHandler public handler;

    function setUp() public {
        vault = new VulnerableShares();
        handler = new VaultHandler(vault);

        targetContract(address(handler));
    }

    function invariant_VaultBalanceMatchesTotalAssets() public view {
        uint256 realBalance = address(vault).balance;
        uint256 trackedAssets = vault.totalAssets();

        if (realBalance > trackedAssets) {
            return;
        }
        assertEq(realBalance, trackedAssets, "Economic stat broken!");
    }
}
