// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title UQ112x112 Fixed-Point Math Library
/// @notice Implements binary fixed-point arithmetic for price accumulators in Avior AMM
/// @dev Encodes uint112 into a 112.112 fixed-point representation (224 bits total).
library UQ112x112 {
    uint224 internal constant Q112 = 2 ** 112;

    /// @notice Encodes a uint112 value as a UQ112x112 binary fixed point number
    function encode(uint112 y) internal pure returns (uint224) {
        return uint224(y) * Q112;
    }

    /// @notice Divides a UQ112x112 number by a uint112 value, returning a UQ112x112 result
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224) {
        return x / uint224(y);
    }
}
