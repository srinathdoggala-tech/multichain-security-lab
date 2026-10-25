// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IAviorCallee.sol";

/// @title AviorAMMPairSecured (Remediated Production-Grade DEX Core)
/// @notice Implements standard constant-product AMM pair security controls:
///         1. NonReentrant execution on swap, mint, burn, sync, and skim.
///         2. Strict fee-adjusted K-invariant validation: (1000*b0 - 3*in0) * (1000*b1 - 3*in1) >= 1000^2 * r0 * r1.
///         3. Permanent MINIMUM_LIQUIDITY (1000 units) dead-address lock on genesis mint.
///         4. Exact balance delta verification preventing donation and desynchronization exploits.
contract AviorAMMPairSecured is ERC20, ReentrancyGuard {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidK();
    error TransferFailed();

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor(address _token0, address _token1) ERC20("Avior Secured LP Token", "AVIOR-SEC-LP") {
        require(_token0 != _token1, "Identical tokens");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "Overflow");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Remediated Genesis Mint: permanently locks MINIMUM_LIQUIDITY to neutralize share inflation attacks
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            uint256 initialLiquidity = _sqrt(amount0 * amount1);
            if (initialLiquidity <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity = initialLiquidity - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Remediated Swap: Protected by nonReentrant and verifies strict 0.3% fee adjusted K-invariant
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        uint256 amount0In;
        uint256 amount1In;
        uint256 balance0;
        uint256 balance1;
        {
            (uint112 _reserve0, uint112 _reserve1,) = getReserves();
            if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

            if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

            if (data.length > 0) {
                IAviorCallee(to).aviorCall(msg.sender, amount0Out, amount1Out, data);
            }

            balance0 = IERC20(token0).balanceOf(address(this));
            balance1 = IERC20(token1).balanceOf(address(this));

            amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
            amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
            if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

            _validateK(balance0, balance1, amount0In, amount1In, _reserve0, _reserve1);
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @dev Internal pure helper to validate 0.3% fee-adjusted constant-product K without stack-too-deep
    function _validateK(
        uint256 balance0,
        uint256 balance1,
        uint256 amount0In,
        uint256 amount1In,
        uint112 _reserve0,
        uint112 _reserve1
    ) internal pure {
        uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
        uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
        if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * uint256(_reserve1) * (1000 ** 2)) {
            revert InvalidK();
        }
    }

    /// @notice Remediated Sync: Protected against reentrancy
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    /// @notice Remediated Skim: Sends excess tokens to caller, protected against underflow and zero-transfer reverts
    function skim(address to) external nonReentrant {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 > _reserve0) {
            _safeTransfer(token0, to, balance0 - _reserve0);
        }
        if (balance1 > _reserve1) {
            _safeTransfer(token1, to, balance1 - _reserve1);
        }
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }
}
