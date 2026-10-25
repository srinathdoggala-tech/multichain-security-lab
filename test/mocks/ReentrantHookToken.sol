// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenHookReceiver {
    function onTokenHook(address from, address to, uint256 amount) external;
}

/// @title ReentrantHookToken (Adversarial DeFi Mock)
/// @notice Simulates ERC-777/ERC-1363 callback-enabled tokens that trigger external hooks during transfers.
contract ReentrantHookToken is ERC20 {
    address public hookTarget;
    bool public hookActive;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address _hookTarget, bool _active) external {
        hookTarget = _hookTarget;
        hookActive = _active;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookActive && hookTarget != address(0) && (to == hookTarget || from == hookTarget)) {
            // Trigger external callback hook (can attempt reentrancy)
            ITokenHookReceiver(hookTarget).onTokenHook(from, to, value);
        }
    }
}
