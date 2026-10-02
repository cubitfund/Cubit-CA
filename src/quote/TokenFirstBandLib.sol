// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BandLib} from "../libraries/BandLib.sol";
import {QuoteBandLib} from "./QuoteBandLib.sol";

/// @title TokenFirstBandLib — prices and wall targets of a child whose token is currency0
/// @notice QuoteBandLib's rules (launch bounds, 40/60 target, 1% under the market, prices at 1e36) for the opposite
///         pool orientation: the child token is currency0 and its ERC-20 quote currency1, so that the pool reads
///         TOKEN/QUOTE everywhere (explorers and aggregators take currency0 as the base). The pool price is quote per
///         token and the pool tick moves WITH the token price:
///
///           token price in the quote goes UP   <=>   pool tick goes UP
///
///         Position geometry: a range is 100% token (currency0) when the price is at or under its lower tick, and
///         100% quote (currency1) when the price is at or above its upper tick. So the token band lives ABOVE the
///         price and the quote walls UNDER it — the mirror image of QuoteBandLib's, tick t there being tick -t here.
library TokenFirstBandLib {
    /// @notice Fixed point of the prices below: quote base units per token base unit, times 1e36.
    uint256 internal constant PRICE_SCALE = 1e36;
    /// @notice QuoteBandLib's launch bounds, mirrored: its highest tick (cheapest token) is the lowest here.
    int24 internal constant MIN_LAUNCH_TICK = -QuoteBandLib.MAX_LAUNCH_TICK;
    int24 internal constant MAX_LAUNCH_TICK = -QuoteBandLib.MIN_LAUNCH_TICK;

    /// @notice The opening sqrtPriceX96 (quote per token) of a pool that values `supply` tokens at `launchValue` quote
    ///         units, and whether the launch is acceptable. The inverse of QuoteBandLib's opening price, accepted on the
    ///         same condition, so that a launch value is valid in both orientations or in neither.
    function launchSqrtPrice(uint256 launchValue, uint256 supply) internal pure returns (bool ok, uint160 sqrtPrice) {
        (bool valid, uint160 inverse) = QuoteBandLib.launchSqrtPrice(launchValue, supply);
        if (!valid) return (false, 0);
        uint256 wide = FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, inverse);
        if (wide <= TickMath.MIN_SQRT_PRICE || wide >= TickMath.MAX_SQRT_PRICE) return (false, 0);
        return (true, uint160(wide));
    }

    /// @notice Quote per token (PRICE_SCALE) at a sqrtPriceX96: 1e36 * sqrtP^2 / 2^192, as QuoteBandLib at the inverse.
    function priceAtSqrt(uint160 sqrtP) internal pure returns (uint256) {
        uint256 x = FullMath.mulDiv(PRICE_SCALE, sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(x, sqrtP, FixedPoint96.Q96);
    }

    /// @notice 40% of the current price plus 60% of the frozen launch price, as a wall's UPPER tick.
    function retracementWallUpper(uint160 launchSqrtP, uint160 currentSqrtP, int24 spacing) internal pure returns (int24) {
        uint256 target = FullMath.mulDiv(priceAtSqrt(currentSqrtP), 10_000 - BandLib.WALL_RETRACEMENT_BPS, 10_000)
            + FullMath.mulDiv(priceAtSqrt(launchSqrtP), BandLib.WALL_RETRACEMENT_BPS, 10_000);
        return wallUpper(target, spacing);
    }

    /// @notice 1% under the current price, for the wall placed at or below the launch price, as an UPPER tick.
    function underMarketWallUpper(uint160 currentSqrtP, int24 spacing) internal pure returns (int24) {
        uint256 current = priceAtSqrt(currentSqrtP);
        return wallUpper(FullMath.mulDiv(current, 10_000 - BandLib.WALL_UNDER_MARKET_BPS, 10_000), spacing);
    }

    /// @notice The upper tick of the one-spacing wall whose every price is strictly under `target` (quote per token,
    ///         PRICE_SCALE): the mirror of BandLib.wallTarget, which rounds a wall's range to the far side of its
    ///         target. Clamped to the bottom of the usable range; the caller checks it is under the market.
    function wallUpper(uint256 target, int24 spacing) internal pure returns (int24 upper) {
        int24 minUpper = TickMath.minUsableTick(spacing) + spacing;
        // sqrt(target / PRICE_SCALE) * 2^96, as sqrt(target * 2^192 / 1e36) = sqrt(target * 2^128 / 1e36) * 2^32.
        uint256 sqrtX96 = target == 0 ? 0 : Math.sqrt(FullMath.mulDiv(target, 1 << 128, PRICE_SCALE)) << 32;
        if (sqrtX96 < TickMath.MIN_SQRT_PRICE) return minUpper;
        int24 t = sqrtX96 >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_TICK : TickMath.getTickAtSqrtPrice(uint160(sqrtX96));
        // P(t) <= target: the highest spacing multiple whose price is strictly under the target.
        upper = BandLib.floorToSpacing(t, spacing);
        if (sqrtX96 < TickMath.MAX_SQRT_PRICE && TickMath.getSqrtPriceAtTick(upper) >= sqrtX96) upper -= spacing;
        int24 maxUpper = TickMath.maxUsableTick(spacing);
        if (upper > maxUpper) upper = maxUpper;
        if (upper < minUpper) upper = minUpper;
    }
}
