// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/ArbitrageVault.sol";

contract ArbitrageBot {
    FlashMinterPool public flashPool;
    CheapDex public cheapDex;
    ExpensiveDex public expensiveDex;
    MockTokenArb public token;
    address public owner;

    constructor(address _flashPool, address _cheapDex, address payable _expensiveDex, address _token) {
        flashPool = FlashMinterPool(_flashPool);
        cheapDex = CheapDex(_cheapDex);
        expensiveDex = ExpensiveDex(_expensiveDex);
        token = MockTokenArb(_token);
        owner = msg.sender;
    }

    function startArbitrage(uint256 amount) external {
        flashPool.flashLoan(amount, address(this));
    }

    function executeOperation(uint256 amount, address) external {
        require(msg.sender == address(flashPool), "Only flash pool");

        token.approve(address(expensiveDex), amount);

        expensiveDex.sellTokens(amount);

        uint256 ethToSpend = amount / 2;
        cheapDex.buyTokens{value: ethToSpend}();

        token.transfer(address(flashPool), amount);

        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}

contract ArbitrageTest is Test {
    MockTokenArb public token;
    FlashMinterPool public flashPool;
    CheapDex public cheapDex;
    ExpensiveDex public expensiveDex;
    ArbitrageBot public bot;

    address public attacker = address(0xBAD);

    function setUp() public {
        token = new MockTokenArb();
        flashPool = new FlashMinterPool(address(token));
        cheapDex = new CheapDex(address(token));
        expensiveDex = new ExpensiveDex(address(token));

        token.mint(address(flashPool), 1_000_000 * 10 ** 18);
        vm.deal(address(expensiveDex), 100 ether);

        bot = new ArbitrageBot(address(flashPool), address(cheapDex), payable(address(expensiveDex)), address(token));
    }

    function testArbitrageExploit() public {
        vm.startPrank(attacker);
        uint256 balanceBefore = address(this).balance;
        bot.startArbitrage(10 * 10 ** 18);
        uint256 balanceAfter = address(this).balance;
        assertEq(balanceAfter - balanceBefore, 5 * 10 ** 18, "Arbitrage profit mismatch");
        vm.stopPrank();
    }
    receive() external payable {}
}
