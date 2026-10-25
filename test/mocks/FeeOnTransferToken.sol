// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferToken (Adversarial DeFi Mock)
/// @notice Simulates deflationary or fee-bearing tokens (e.g., PAXG, STA) that deduct a fee on every transfer.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBasisPoints; // e.g. 500 = 5%
    address public feeRecipient;

    constructor(string memory name, string memory symbol, uint256 _feeBasisPoints, address _feeRecipient)
        ERC20(name, symbol)
    {
        require(_feeBasisPoints <= 2000, "Fee too high"); // max 20%
        feeBasisPoints = _feeBasisPoints;
        feeRecipient = _feeRecipient;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBasisPoints(uint256 _feeBasisPoints) external {
        require(_feeBasisPoints <= 2000, "Fee too high");
        feeBasisPoints = _feeBasisPoints;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBasisPoints == 0 || from == feeRecipient || to == feeRecipient)
        {
            super._update(from, to, value);
        } else {
            uint256 fee = (value * feeBasisPoints) / 10000;
            uint256 netValue = value - fee;
            super._update(from, feeRecipient, fee);
            super._update(from, to, netValue);
        }
    }
}
