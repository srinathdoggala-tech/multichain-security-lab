// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./AviorAMMPairSecured.sol";
import "./libraries/UQ112x112.sol";

/// @title AviorTWAPOracle (Time-Weighted Average Price Oracle)
/// @notice Implements a manipulation-resistant TWAP oracle module based on cumulative price accumulators.
/// @dev Secures protocols against single-block flash loan price manipulation by measuring price
///      integral over time rather than instantaneous spot reserves.
contract AviorTWAPOracle {
    using UQ112x112 for uint224;

    AviorAMMPairSecured public immutable pair;
    address public immutable token0;
    address public immutable token1;

    uint256 public immutable period;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    uint224 public price0Average; // UQ112x112 fixed-point representation
    uint224 public price1Average; // UQ112x112 fixed-point representation

    error PeriodNotElapsed(uint32 timeElapsed, uint256 minPeriod);
    error InvalidPeriod();
    error InvalidToken();
    error ZeroReserves();
    error OracleNotInitialized();
    error StalePrice(uint32 age, uint256 maxAge);

    event OracleUpdated(
        uint224 price0Average,
        uint224 price1Average,
        uint32 blockTimestampLast,
        uint256 price0Cumulative,
        uint256 price1Cumulative
    );

    /// @param _pair Address of the AviorAMMPairSecured pool
    /// @param _period Minimum elapsed time window (in seconds) required between oracle updates
    constructor(address _pair, uint256 _period) {
        if (_period == 0) revert InvalidPeriod();
        pair = AviorAMMPairSecured(_pair);
        token0 = pair.token0();
        token1 = pair.token1();
        period = _period;

        price0CumulativeLast = pair.price0CumulativeLast();
        price1CumulativeLast = pair.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 _blockTimestampLast) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert ZeroReserves();
        blockTimestampLast = _blockTimestampLast;
    }

    /// @notice Returns current cumulative prices for the pair, extrapolating forward if current block time advanced
    function currentCumulativePrices()
        public
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = uint32(block.timestamp % 2 ** 32);
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 pairTimestampLast) = pair.getReserves();
        if (pairTimestampLast != blockTimestamp && reserve0 != 0 && reserve1 != 0) {
            uint32 timeElapsed;
            unchecked {
                timeElapsed = blockTimestamp - pairTimestampLast;
            }
            unchecked {
                price0Cumulative += uint256(UQ112x112.uqdiv(UQ112x112.encode(reserve1), reserve0)) * timeElapsed;
                price1Cumulative += uint256(UQ112x112.uqdiv(UQ112x112.encode(reserve0), reserve1)) * timeElapsed;
            }
        }
    }

    /// @notice Updates the time-weighted average price snapshot once the required period has elapsed
    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices();
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        if (timeElapsed < period) revert PeriodNotElapsed(timeElapsed, period);

        // Arithmetic overflow is desired in two's complement subtraction:
        // (priceCumulative - priceCumulativeLast) correctly computes difference across uint256 overflow
        unchecked {
            price0Average = uint224((price0Cumulative - price0CumulativeLast) / timeElapsed);
            price1Average = uint224((price1Cumulative - price1CumulativeLast) / timeElapsed);
        }

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;

        emit OracleUpdated(price0Average, price1Average, blockTimestampLast, price0Cumulative, price1Cumulative);
    }

    /// @notice Returns the age (in seconds) of the current TWAP price observation
    /// @dev ASSUMPTION & LIMITATION: Relies on `uint32` modular arithmetic matching `pair.blockTimestampLast`.
    ///      If the oracle is neglected for >= 2^32 seconds (~136.19 years), `age` wraps modulo 2^32.
    ///      Consequently, `isStale(maxAge)` and `consult(..., maxAge)` cannot detect staleness for intervals >= 2^32 seconds.
    ///      Integrators must ensure keepers invoke `update()` at least once per 136-year epoch.
    function observationAge() public view returns (uint32 age) {
        unchecked {
            age = uint32(block.timestamp % 2 ** 32) - blockTimestampLast;
        }
    }

    /// @notice Returns true if the observation age exceeds maxAge seconds
    /// @dev Subject to the uint32 modular wrap assumption (see `observationAge()`).
    function isStale(uint256 maxAge) external view returns (bool) {
        return observationAge() > maxAge;
    }

    /// @notice Computes expected output amount based on TWAP with fail-closed default staleness limit (2 * period)
    /// @dev Fail-closed default: reverts with `StalePrice` if `observationAge() > 2 * period`.
    ///      Prevents accidental consumption of stale historical prices by naive integrators.
    /// @param token Input token address (must be token0 or token1)
    /// @param amountIn Amount of input token
    /// @return amountOut Converted amount of counter-asset based on TWAP
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        return consult(token, amountIn, period * 2);
    }

    /// @notice Computes expected output amount with explicit caller-defined maximum staleness validation
    /// @dev Reverts with `StalePrice` if `observationAge() > maxAge`. Recommended entry point for on-chain DeFi protocols.
    ///      Note: Cannot detect staleness if elapsed time wraps across 2^32 seconds (see `observationAge()`).
    /// @param token Input token address (must be token0 or token1)
    /// @param amountIn Amount of input token
    /// @param maxAge Maximum acceptable elapsed time (in seconds) since last oracle snapshot
    /// @return amountOut Converted amount of counter-asset based on TWAP
    function consult(address token, uint256 amountIn, uint256 maxAge) public view returns (uint256 amountOut) {
        uint32 age = observationAge();
        if (age > maxAge) revert StalePrice(age, maxAge);
        return consultUnchecked(token, amountIn);
    }

    /// @notice Computes expected output amount based on last recorded TWAP snapshot without staleness enforcement
    /// @dev WARNING - UNCHECKED INTERFACE: Does NOT validate observation age. If keepers fail to update the oracle,
    ///      it will return arbitrary historical prices. Security-sensitive integrations (e.g., lending collateral,
    ///      liquidations) MUST NOT use this function. Provided strictly for off-chain view analytics, historical
    ///      backtesting, or callers performing custom off-chain timestamp validation.
    /// @param token Input token address (must be token0 or token1)
    /// @param amountIn Amount of input token
    /// @return amountOut Converted amount of counter-asset based on TWAP
    function consultUnchecked(address token, uint256 amountIn) public view returns (uint256 amountOut) {
        if (price0Average == 0 || price1Average == 0) revert OracleNotInitialized();

        if (token == token0) {
            // price0Average is in UQ112x112 format: amountOut = (price0Average * amountIn) / 2^112
            amountOut = (uint256(price0Average) * amountIn) >> 112;
        } else if (token == token1) {
            // price1Average is in UQ112x112 format: amountOut = (price1Average * amountIn) / 2^112
            amountOut = (uint256(price1Average) * amountIn) >> 112;
        } else {
            revert InvalidToken();
        }
    }

    /// @notice Computes instantaneous spot conversion using current reserves (for vulnerability / manipulation comparison)
    /// @param token Input token address
    /// @param amountIn Amount of input token
    /// @return amountOut Instantaneous spot output (vulnerable to flash-loan manipulation)
    function consultSpot(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert ZeroReserves();

        if (token == token0) {
            amountOut = (amountIn * uint256(reserve1)) / uint256(reserve0);
        } else if (token == token1) {
            amountOut = (amountIn * uint256(reserve0)) / uint256(reserve1);
        } else {
            revert InvalidToken();
        }
    }
}
