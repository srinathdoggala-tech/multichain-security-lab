// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAviorCallee - Flash Swap Callback Interface for Avior DEX
/// @notice Implemented by contracts wishing to receive flash swaps or callback execution
interface IAviorCallee {
    function aviorCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}
