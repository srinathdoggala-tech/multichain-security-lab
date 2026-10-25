// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockTokenArb {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FlashMinterPool {
    MockTokenArb public token;

    constructor(address _token) {
        token = MockTokenArb(_token);
    }

    function flashLoan(uint256 amount, address receiver) external {
        uint256 balanceBefore = token.balanceOf(address(this));
        require(balanceBefore >= amount, "Not enough liquidity");

        token.transfer(receiver, amount);

        (bool success,) =
            receiver.call(abi.encodeWithSignature("executeOperation(uint256,address)", amount, msg.sender));
        require(success, "Flash loan execution failed");

        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Flash loan not repaid");
    }
}

contract CheapDex {
    MockTokenArb public token;

    constructor(address _token) {
        token = MockTokenArb(_token);
    }

    function buyTokens() external payable {
        uint256 tokensToMint = msg.value * 2;
        token.mint(msg.sender, tokensToMint);
    }
}

contract ExpensiveDex {
    MockTokenArb public token;

    constructor(address _token) {
        token = MockTokenArb(_token);
    }

    function sellTokens(uint256 tokenAmount) external {
        bool success = token.transferFrom(msg.sender, address(this), tokenAmount);
        require(success, "Transfer from failed");

        payable(msg.sender).transfer(tokenAmount);
    }

    receive() external payable {}
}
