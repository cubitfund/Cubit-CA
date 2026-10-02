// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BandLib — pure geometry of the CUBIT order book
/// @notice Computes the wall targets and the liquidity/amount roundings of the band and the walls.
///         No state, no external calls.
///
/// @dev ORIENTATION. The pool is CUBIT/ETH with native ETH as currency0 (address 0 sorts
///      first). The pool price is therefore `currency1 / currency0` = CUBIT per ETH, and the
///      pool tick moves in the OPPOSITE direction of the CUBIT price expressed in ETH:
///
///          CUBIT price in ETH goes UP   <=>   pool tick goes DOWN
///
///      Every function here works in pool orientation; the hook exposes ETH-per-CUBIT prices.
///
///      Position geometry in pool orientation:
///        - a position is 100% ETH   (currency0) when  currentTick <  tickLower
///        - a position is 100% CUBIT (currency1) when  currentTick >= tickUpper
///      so the ETH walls live ABOVE the current tick and the CUBIT band BELOW it.
library BandLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant WALL_RETRACEMENT_BPS = 6000;
    /// @notice How far under the market a wall goes when the 40/60 target is not under it (at or below launch).
    uint256 internal constant WALL_UNDER_MARKET_BPS = 100;

    // ---------------------------------------------------------------------------------------
    // Tick rounding
    // ---------------------------------------------------------------------------------------

    /// @notice Largest multiple of `spacing` that is <= tick.
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    /// @notice Smallest multiple of `spacing` that is >= tick.
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = floorToSpacing(tick, spacing);
        return f == tick ? f : f + spacing;
    }

    // ---------------------------------------------------------------------------------------
    // Wall geometry
    // ---------------------------------------------------------------------------------------

    /// @notice At time T: 40% of the current price plus 60% of the frozen launch price.
    /// @dev No historical maximum, ratchet or dependence on old wall prices. A target above
    /// the market (possible below launch) cannot be funded as pure ETH: the hook defers it.
    function retracementWallTarget(uint160 launchSqrtPrice, uint160 currentSqrtPrice, int24 spacing)
        public pure returns (int24)
    {
        uint256 base = ethPerCubitAtSqrt(launchSqrtPrice);
        uint256 current = ethPerCubitAtSqrt(currentSqrtPrice);
        uint256 target = (current * (10_000 - WALL_RETRACEMENT_BPS) + base * WALL_RETRACEMENT_BPS) / 10_000;
        return wallTarget(target, WAD, TickMath.MIN_TICK, spacing);
    }

    /// @notice The wall at or below the launch price, where the 40/60 target is at or above the market:
    ///         1% under the current price, so the funds are placed now rather than left for a later sale.
    /// @dev    Strictly under the market by at least 1% (wallTarget rounds the range below the ratio), and
    ///         clamped like wallTarget: at the top of the tick range the caller finds no room and keeps the funds.
    function underMarketWallTarget(uint160 currentSqrtPrice, int24 spacing) public pure returns (int24) {
        uint256 current = ethPerCubitAtSqrt(currentSqrtPrice);
        return wallTarget(current * (10_000 - WALL_UNDER_MARKET_BPS) / 10_000, WAD, TickMath.MIN_TICK, spacing);
    }

    /// @notice sqrtPriceX96 of the pool price C/E (CUBIT per ETH) for a floor f = E/C.
    /// @dev    sqrt(C/E) * 2^96 = sqrt((C << 128) / E) << 32. C < 2^85 so no overflow.
    function sqrtPriceForRatio(uint256 ethE, uint256 supplyC) internal pure returns (uint256) {
        if (ethE == 0) return type(uint256).max;
        uint256 ratioX128 = (supplyC << 128) / ethE;
        return Math.sqrt(ratioX128) << 32;
    }

    /// @notice Lower tick of the wall for a floor f = ethE / supplyC.
    /// @dev    The wall must execute at prices <= f (SPEC §3.2: P_exec < f), so its lower
    ///         tick (highest ETH price of the range) must satisfy P(tickLower) > C/E; it must
    ///         also sit strictly above the current tick (100% ETH position, "one notch under
    ///         the spot" when f exceeds the market) and leave room for one spacing at the top.
    ///         Never reverts: extreme ratios are clamped.
    function wallTarget(uint256 ethE, uint256 supplyC, int24 spotTick, int24 spacing)
        public
        pure
        returns (int24 lower)
    {
        int24 maxLower = TickMath.maxUsableTick(spacing) - spacing;
        int24 cap = ceilToSpacing(spotTick + 1, spacing);

        int24 t;
        uint256 sqrtX96 = sqrtPriceForRatio(ethE, supplyC);
        if (sqrtX96 >= TickMath.MAX_SQRT_PRICE) t = TickMath.MAX_TICK;
        else if (sqrtX96 < TickMath.MIN_SQRT_PRICE) t = TickMath.MIN_TICK;
        else t = TickMath.getTickAtSqrtPrice(uint160(sqrtX96));

        // P(t) <= C/E < P(t+1): the first tick whose price is strictly above the ratio is t+1
        lower = ceilToSpacing(t + 1, spacing);
        if (lower < cap) lower = cap;
        if (lower > maxLower) lower = maxLower;
    }

    // ---------------------------------------------------------------------------------------
    // Liquidity roundings (never deposit more than we hold, never overflow a tick)
    // ---------------------------------------------------------------------------------------

    /// @notice The per-tick liquidity ceiling the PoolManager enforces for this tick spacing.
    /// @dev    A narrow position at an extreme tick converts a modest amount of ETH into an
    ///         enormous liquidity number, so this ceiling is reachable in practice — see
    ///         `liquidityForEth`. Exceeding it reverts the whole modifyLiquidity call.
    function maxLiquidityPerTick(int24 spacing) internal pure returns (uint128) {
        return Pool.tickSpacingToMaxLiquidityPerTick(spacing);
    }

    /// @notice Liquidity for a 100%-ETH position holding at most `amount0`; `used` is the exact
    ///         amount the PoolManager will charge (rounded up), guaranteed <= amount0.
    /// @dev    Capped at `maxLiquidity`, and the cap is applied to the FULL-WIDTH uint256 result
    ///         before any cast: at very low CUBIT prices (very high pool ticks) the implied
    ///         liquidity exceeds not just the pool's per-tick ceiling but `type(uint128).max`
    ///         itself, and `LiquidityAmounts.getLiquidityForAmount0` would revert in its own
    ///         SafeCast before a post-hoc cap could run. Degrade cleanly, never revert
    ///         (CONTRACT_SPEC §10).
    function liquidityForEth(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0, uint128 maxLiquidity)
        public
        pure
        returns (uint128 liquidity, uint256 used)
    {
        if (amount0 == 0) return (0, 0);
        // same maths as LiquidityAmounts.getLiquidityForAmount0, kept in uint256
        uint256 intermediate = FullMath.mulDiv(sqrtLower, sqrtUpper, FixedPoint96.Q96);
        uint256 wide = FullMath.mulDiv(amount0, intermediate, uint256(sqrtUpper) - sqrtLower);
        liquidity = wide > maxLiquidity ? maxLiquidity : uint128(wide);
        used = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        while (used > amount0 && liquidity > 0) {
            liquidity--;
            used = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        if (liquidity == 0) used = 0;
    }

    /// @notice Liquidity for a 100%-CUBIT position holding at most `amount1`, capped like above
    ///         and for the same reason (the cast happens after the clamp, never before).
    function liquidityForTokens(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1, uint128 maxLiquidity)
        public
        pure
        returns (uint128 liquidity, uint256 used)
    {
        if (amount1 == 0) return (0, 0);
        uint256 wide = FullMath.mulDiv(amount1, FixedPoint96.Q96, uint256(sqrtUpper) - sqrtLower);
        liquidity = wide > maxLiquidity ? maxLiquidity : uint128(wide);
        used = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        while (used > amount1 && liquidity > 0) {
            liquidity--;
            used = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        if (liquidity == 0) used = 0;
    }

    /// @notice Amounts (ETH, CUBIT) currently held by a position at price `sqrtP` (rounded down).
    function amountsForLiquidity(uint160 sqrtP, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Prices in ETH per CUBIT (1e18 fixed point) — the orientation of the specification
    // ---------------------------------------------------------------------------------------

    /// @notice ETH per CUBIT (WAD) at a given sqrtPriceX96: 1e18 * 2^192 / sqrtP^2.
    function ethPerCubitAtSqrt(uint160 sqrtP) internal pure returns (uint256) {
        uint256 x = FullMath.mulDiv(WAD, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDiv(x, FixedPoint96.Q96, sqrtP);
    }

    /// @notice ETH per CUBIT (WAD) at a tick.
    function ethPerCubitAtTick(int24 tick) internal pure returns (uint256) {
        return ethPerCubitAtSqrt(TickMath.getSqrtPriceAtTick(tick));
    }
}
