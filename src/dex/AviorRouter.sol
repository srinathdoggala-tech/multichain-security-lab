// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AviorAMMPairSecured.sol";

/// @title AviorRouter - Multi-Hop Swap & Slippage Protection Router for Avior DEX
/// @notice Handles exact-input multi-hop routing, strict slippage enforcement, deadline validation, and safe asset transfers
contract AviorRouter {
    using SafeERC20 for IERC20;

    address public immutable owner;
    mapping(address => mapping(address => address)) public getPair;

    error ExpiredDeadline();
    error InvalidPathLength();
    error IdenticalTokens();
    error ZeroAddress();
    error PairNotFound(address tokenA, address tokenB);
    error InsufficientInputAmount();
    error InsufficientOutputAmount(uint256 expectedMin, uint256 actual);
    error InsufficientLiquidity();
    error Unauthorized();

    event PairRegistered(address indexed tokenA, address indexed tokenB, address indexed pair);
    event SwapRouted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    );

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Registers an authorized AMM pair for a token pair
    function registerPair(address tokenA, address tokenB, address pair) external {
        if (msg.sender != owner) revert Unauthorized();
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0) || pair == address(0)) revert ZeroAddress();

        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        emit PairRegistered(tokenA, tokenB, pair);
    }

    /// @notice Resolves pair address with validation
    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        pair = getPair[tokenA][tokenB];
        if (pair == address(0)) revert PairNotFound(tokenA, tokenB);
    }

    /// @notice Given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientInputAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Performs chained getAmountOut calculations along any multi-hop path
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPathLength();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            if (path[i] == path[i + 1]) revert IdenticalTokens();
            address pair = pairFor(path[i], path[i + 1]);
            (uint112 reserve0, uint112 reserve1,) = AviorAMMPairSecured(pair).getReserves();
            address token0 = AviorAMMPairSecured(pair).token0();

            (uint256 reserveIn, uint256 reserveOut) = path[i] == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice Swaps exact tokens for tokens along a specified path with strict slippage and deadline enforcement
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (to == address(0)) revert ZeroAddress();
        amounts = getAmountsOut(amountIn, path);
        uint256 finalAmountOut = amounts[amounts.length - 1];
        if (finalAmountOut < amountOutMin) revert InsufficientOutputAmount(amountOutMin, finalAmountOut);

        // Transfer initial input tokens from sender directly to the first pair
        IERC20(path[0]).safeTransferFrom(msg.sender, pairFor(path[0], path[1]), amounts[0]);

        // Route swaps across all hops
        _executeHops(amounts, path, to);

        emit SwapRouted(msg.sender, path[0], path[path.length - 1], amountIn, finalAmountOut, to);
    }

    /// @dev Internal helper to execute all hops along the path
    function _executeHops(uint256[] memory amounts, address[] calldata path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            _swapHop(amounts, path, i, to);
        }
    }

    /// @dev Internal helper to execute a single hop, isolating local variables from stack-too-deep
    function _swapHop(uint256[] memory amounts, address[] calldata path, uint256 i, address to) internal {
        address input = path[i];
        address output = path[i + 1];
        address pair = pairFor(input, output);
        address token0 = AviorAMMPairSecured(pair).token0();

        uint256 amountOut = amounts[i + 1];
        (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

        address recipient = i < path.length - 2 ? pairFor(output, path[i + 2]) : to;
        AviorAMMPairSecured(pair).swap(amount0Out, amount1Out, recipient, new bytes(0));
    }
}
