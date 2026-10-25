// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {AccountingDriftVault as VulnerableVault} from "../src/AccountingDriftVault.sol";
import {AccountingDriftVault as FixedVault} from "../src/AccountingDriftVaultFixed.sol";

contract Reenterer {
    FixedVault immutable vault;

    constructor(FixedVault v) {
        vault = v;
    }

    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw(msg.value);
    }

    receive() external payable {
        vault.withdraw(1);
    }
}

contract AccountingDriftVaultTest is Test {
    VulnerableVault vulnerable;
    FixedVault fixedVault;

    address attacker = address(0x1337);
    address victim = address(0xBEEF);
    address newUser = address(0xCAFE);

    function setUp() public {
        vulnerable = new VulnerableVault();
        fixedVault = new FixedVault();
        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(newUser, 100 ether);
    }

    function test_Vulnerable_SingleDepositorOverpaid() public {
        vm.prank(attacker);
        vulnerable.deposit{value: 100 ether}();

        vm.prank(attacker);
        vulnerable.withdraw(50 ether);

        assertEq(attacker.balance, 100 ether);
        assertEq(vulnerable.balanceOf(attacker), 50 ether);
        assertEq(vulnerable.totalAssets(), 0);
        assertEq(vulnerable.totalShares(), 50 ether);
        assertEq(address(vulnerable).balance, 0);
        assertTrue(vulnerable.totalShares() != vulnerable.totalAssets());
    }

    function test_Vulnerable_AttackerDrainsVictim() public {
        _drainVulnerable();

        assertEq(attacker.balance, 200 ether);
        assertEq(address(vulnerable).balance, 0);
        assertEq(vulnerable.totalAssets(), 0);

        assertEq(vulnerable.balanceOf(victim), 100 ether);
        assertEq(vulnerable.totalShares(), 100 ether);
    }

    function test_Vulnerable_VictimCannotWithdraw() public {
        _drainVulnerable();

        vm.expectRevert(stdError.divisionError);
        vm.prank(victim);
        vulnerable.withdraw(100 ether);
    }

    function test_Vulnerable_DepositsBrickedAfterDrain() public {
        _drainVulnerable();

        vm.expectRevert(stdError.divisionError);
        vm.prank(newUser);
        vulnerable.deposit{value: 1 ether}();
    }

    function _drainVulnerable() internal {
        vm.prank(attacker);
        vulnerable.deposit{value: 100 ether}();
        vm.prank(victim);
        vulnerable.deposit{value: 100 ether}();

        vm.prank(attacker);
        vulnerable.withdraw(100 ether);
    }

    function test_Fixed_SameScenarioPaysProRata() public {
        vm.prank(attacker);
        fixedVault.deposit{value: 100 ether}();
        vm.prank(victim);
        fixedVault.deposit{value: 100 ether}();

        vm.prank(attacker);
        fixedVault.withdraw(100 ether);
        assertEq(attacker.balance, 100 ether);

        vm.prank(victim);
        fixedVault.withdraw(100 ether);
        assertEq(victim.balance, 100 ether);

        assertEq(fixedVault.totalShares(), 0);
        assertEq(fixedVault.totalAssets(), 0);
        assertEq(address(fixedVault).balance, 0);
    }

    function test_Fixed_PartialWithdrawKeepsBooksBalanced() public {
        vm.prank(attacker);
        fixedVault.deposit{value: 100 ether}();

        vm.prank(attacker);
        fixedVault.withdraw(50 ether);

        assertEq(attacker.balance, 50 ether);
        assertEq(fixedVault.totalAssets(), 50 ether);
        assertEq(fixedVault.totalShares(), 50 ether);
        assertEq(address(fixedVault).balance, 50 ether);
    }

    function test_Fixed_RevertsOnZeroOrExcessShares() public {
        vm.prank(attacker);
        fixedVault.deposit{value: 10 ether}();

        vm.expectRevert("Zero shares");
        vm.prank(attacker);
        fixedVault.withdraw(0);

        vm.expectRevert("Low shares balance");
        vm.prank(attacker);
        fixedVault.withdraw(11 ether);
    }

    function test_Fixed_ReentrancyFails() public {
        vm.prank(victim);
        fixedVault.deposit{value: 100 ether}();

        Reenterer r = new Reenterer(fixedVault);

        vm.expectRevert("Transfer failed");
        vm.prank(attacker);
        r.attack{value: 10 ether}();

        assertEq(address(fixedVault).balance, 100 ether);
    }

    function testFuzz_Fixed_WithdrawPaysProRata(uint96 a, uint96 b, uint256 sharesSeed) public {
        a = uint96(bound(a, 1 ether, 1_000 ether));
        b = uint96(bound(b, 1 ether, 1_000 ether));
        vm.deal(attacker, a);
        vm.deal(victim, b);

        vm.prank(attacker);
        fixedVault.deposit{value: a}();
        vm.prank(victim);
        fixedVault.deposit{value: b}();

        uint256 shares = bound(sharesSeed, 1, fixedVault.balanceOf(attacker));
        uint256 expected = (shares * fixedVault.totalAssets()) / fixedVault.totalShares();

        uint256 balBefore = attacker.balance;
        vm.prank(attacker);
        fixedVault.withdraw(shares);

        assertEq(attacker.balance - balBefore, expected);
        assertEq(fixedVault.totalShares(), fixedVault.totalAssets());
        assertEq(address(fixedVault).balance, fixedVault.totalAssets());
        assertEq(
            fixedVault.balanceOf(attacker) + fixedVault.balanceOf(victim),
            fixedVault.totalShares()
        );
    }
}
contract Handler is Test{
    FixedVault vault;

    constructor(FixedVault v) {
        vault = v;
    }

    function deposit(uint256 amountSeed) public {
    if (address(this).balance < 1 ether) {
        return;
    }
    uint256 amount = bound(amountSeed, 1 ether, address(this).balance);
    vault.deposit{value: amount}();
    }

    function withdraw(uint256 sharesSeed) public {
        if (vault.balanceOf(msg.sender) == 0) {
            return;
        }
        uint256 shares = bound(sharesSeed, 1, vault.balanceOf(msg.sender));
        vault.withdraw(shares);
    }
}
contract InvariantTest is Test {
    FixedVault vault;
    Handler handler;

    function setUp() public {
    vault = new FixedVault();
    handler = new Handler(vault);
    vm.deal(address(handler), 1000 ether);
    targetContract(address(handler));
    }

    function invariant_SharesEqualAssets() public {
        assertEq(vault.totalShares(), vault.totalAssets());
    }
}
contract Handler2 is Test{
    VulnerableVault vault;
    address[] public depositors;

    constructor(VulnerableVault v2) {
        vault = v2;
    }

   function deposit(uint256 amountSeed, uint256 addressSeed) public {
    address randomUser = address(uint160(addressSeed));
    vm.deal(randomUser, 1000 ether);

    if (randomUser.balance < 1 ether) {
        return;
    }

    uint256 amount = bound(amountSeed, 1 ether, randomUser.balance);
    vm.prank(randomUser);
    vault.deposit{value: amount}();
    depositors.push(randomUser);
}

    function withdraw(uint256 sharesSeed, uint256 indexSeed) public {
    if (depositors.length == 0) {
        return;
    }

    uint256 index = bound(indexSeed, 0, depositors.length - 1);
    address randomUser = depositors[index];

    if (vault.balanceOf(randomUser) == 0) {
        return;
    }

    uint256 shares = bound(sharesSeed, 1, vault.balanceOf(randomUser));
    vm.prank(randomUser);
    vault.withdraw(shares);
}
}
contract InvariantTestVulnerable is Test {
    VulnerableVault vault;
    Handler2 handler;

    function setUp() public {
        vault = new VulnerableVault();
        handler = new Handler2(vault);
        vm.deal(address(handler), 1000 ether);
        targetContract(address(handler));
    }

    function invariant_SharesEqualAssets() public {
        assertEq(vault.totalShares(), vault.totalAssets());
    }
}