// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

contract UniV3OracleLending {
    IERC20 public collateralToken;
    IERC20 public borrowToken;
    IUniswapV3Pool public v3Pool;
    uint32 public twapPeriod;
    mapping(address => uint256) public userCollateral;

    constructor(address _collateral, address _borrow, address _pool, uint32 _period) {
        collateralToken = IERC20(_collateral);
        borrowToken = IERC20(_borrow);
        v3Pool = IUniswapV3Pool(_pool);
        twapPeriod = _period;
    }

    function getTwapPrice() public view returns (uint256 price) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = v3Pool.observe(secondsAgos);
        int56 tickCumulDiff = tickCumulatives[1] - tickCumulatives[0];
        // forge-lint:disable-next-line unsafe-typecast [twapPeriod fits in int32]
        int56 rawTick = tickCumulDiff / int56(int32(twapPeriod));
        require(rawTick >= type(int24).min && rawTick <= type(int24).max, "Tick overflow");
        // forge-lint:disable-next-line unsafe-typecast [rawTick is bounded by require]
        int24 timeWeightedAverageTick = int24(rawTick);
        return getPriceFromTick(timeWeightedAverageTick);
    }

    function getPriceFromTick(int24 tick) public pure returns (uint256) {
        // forge-lint:disable-next-line unsafe-typecast [tick conversion is safe]
        if (tick > 0) return uint256(int256(tick)) * 10 ** 18;
        return 10 ** 18;
    }

    function depositCollateral(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        userCollateral[msg.sender] += amount;
    }

    function borrow() external {
        uint256 collateral = userCollateral[msg.sender];
        require(collateral > 0, "No collateral");
        uint256 simulatedPrice = getTwapPrice();
        uint256 borrowAmount = (collateral * simulatedPrice) / 10 ** 18;
        borrowToken.transfer(msg.sender, borrowAmount);
    }
}
