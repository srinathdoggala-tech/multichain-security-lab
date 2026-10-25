// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RebasingToken (Adversarial DeFi Mock)
/// @notice Simulates elastic-supply tokens (e.g., AMPL, stETH) where balances dynamically expand or contract.
contract RebasingToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 private _totalShares;
    uint256 private _totalVirtualSupply;

    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances;

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory _name, string memory _symbol, uint256 initialSupply) {
        name = _name;
        symbol = _symbol;
        _totalShares = initialSupply;
        _totalVirtualSupply = initialSupply;
        _shares[msg.sender] = initialSupply;
        emit Transfer(address(0), msg.sender, initialSupply);
    }

    function totalSupply() public view override returns (uint256) {
        return _totalVirtualSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_totalShares == 0) return 0;
        return (_shares[account] * _totalVirtualSupply) / _totalShares;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert InsufficientAllowance();
            _allowances[from][msg.sender] = currentAllowance - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        uint256 shareAmount = (amount * _totalShares) / _totalVirtualSupply;
        if (_shares[from] < shareAmount) revert InsufficientBalance();

        _shares[from] -= shareAmount;
        _shares[to] += shareAmount;
        emit Transfer(from, to, amount);
    }

    function mint(address to, uint256 amount) external {
        if (_totalVirtualSupply == 0) {
            _totalShares = amount;
            _totalVirtualSupply = amount;
            _shares[to] = amount;
        } else {
            uint256 shareAmount = (amount * _totalShares) / _totalVirtualSupply;
            _totalShares += shareAmount;
            _totalVirtualSupply += amount;
            _shares[to] += shareAmount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Simulates an elastic rebase event changing total balance across all holders without transfers
    /// @param newTotalSupply The updated total supply after rebase
    function rebase(uint256 newTotalSupply) external {
        require(newTotalSupply > 0, "Invalid supply");
        _totalVirtualSupply = newTotalSupply;
    }
}
