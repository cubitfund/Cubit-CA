// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {BandLib} from "../libraries/BandLib.sol";

/// @title QuoteBandLib — wall targets of a launchpad v2 child, whatever its quote currency
/// @notice The same 40/60 and 1% rules as BandLib, with prices carried at 1e36 instead of 1e18. A child pool pairs
///         its token (18 decimals, 21M supply) with a quote that may have 6 decimals (USDC, USDT) or 8 (WBTC): at
///         1e18 its launch price, in quote base units per token base unit, would round to a few units or to zero.
///         At 1e36 it keeps at least 17 significant digits for every quote and launch value the hook accepts.
/// @dev    Pool orientation as in BandLib: the quote is currency0, the child token currency1, and the pool tick
///         moves opposite to the token price. `BandLib.wallTarget` does the tick rounding and clamping unchanged.
library QuoteBandLib {
    /// @notice Fixed point of the prices below: quote base units per token base unit, times 1e36.
    uint256 internal constant PRICE_SCALE = 1e36;
    /// @notice Highest accepted launch tick (cheapest token). Above it, the room left for walls above the price
    ///         shrinks toward nothing; at it, walls keep about 287,000 ticks.
    int24 internal constant MAX_LAUNCH_TICK = 600_000;
    /// @notice Lowest accepted launch tick (dearest token). Below about -340,000 the band's liquidity for 21M tokens
    ///         exceeds the per-tick ceiling and the bootstrap could not deposit the supply; at -300,000 it stays about
    ///         seven times under that ceiling.
    int24 internal constant MIN_LAUNCH_TICK = -300_000;

    /// @notice The opening sqrtPriceX96 of a pool that values `supply` tokens at `launchValue` quote units, and whether
    ///         it is acceptable: a non-zero value whose price is representable and whose tick is within
    ///         [MIN_LAUNCH_TICK, MAX_LAUNCH_TICK].
    function launchSqrtPrice(uint256 launchValue, uint256 supply) internal pure returns (bool ok, uint160 sqrtPrice) {
        if (launchValue == 0) return (false, 0);
        uint256 wide = BandLib.sqrtPriceForRatio(launchValue, supply);
        if (wide < TickMath.MIN_SQRT_PRICE || wide >= TickMath.MAX_SQRT_PRICE) return (false, 0);
        sqrtPrice = uint160(wide);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        ok = tick <= MAX_LAUNCH_TICK && tick >= MIN_LAUNCH_TICK;
    }

    /// @notice Quote per token (PRICE_SCALE) at a given sqrtPriceX96: 1e36 * 2^192 / sqrtP^2.
    /// @dev    At MIN_SQRT_PRICE the result is about 3.4e74, below 2^256: never overflows.
    function priceAtSqrt(uint160 sqrtP) internal pure returns (uint256) {
        uint256 x = FullMath.mulDiv(PRICE_SCALE, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDiv(x, FixedPoint96.Q96, sqrtP);
    }

    /// @notice 40% of the current price plus 60% of the frozen launch price, as a wall's lower tick.
    /// @dev    Each weight is applied with mulDiv so that an extreme current price cannot overflow the sum.
    function retracementWallTarget(uint160 launchSqrtP, uint160 currentSqrtP, int24 spacing)
        internal pure returns (int24)
    {
        uint256 target = FullMath.mulDiv(priceAtSqrt(currentSqrtP), 10_000 - BandLib.WALL_RETRACEMENT_BPS, 10_000)
            + FullMath.mulDiv(priceAtSqrt(launchSqrtP), BandLib.WALL_RETRACEMENT_BPS, 10_000);
        return BandLib.wallTarget(target, PRICE_SCALE, TickMath.MIN_TICK, spacing);
    }

    /// @notice 1% under the current price, for the wall placed at or below the launch price.
    function underMarketWallTarget(uint160 currentSqrtP, int24 spacing) internal pure returns (int24) {
        uint256 current = priceAtSqrt(currentSqrtP);
        uint256 target = FullMath.mulDiv(current, 10_000 - BandLib.WALL_UNDER_MARKET_BPS, 10_000);
        return BandLib.wallTarget(target, PRICE_SCALE, TickMath.MIN_TICK, spacing);
    }
}
