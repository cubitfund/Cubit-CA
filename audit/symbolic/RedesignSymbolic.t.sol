// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {BandLib} from "../../src/libraries/BandLib.sol";
import {WallLib} from "../../src/libraries/WallLib.sol";
import {CubitHook} from "../../src/CubitHook.sol";
import {CubitToken} from "../../src/CubitToken.sol";
import {CubitVault} from "../../src/periphery/CubitVault.sol";
import {CubitGovernanceVault} from "../../src/periphery/CubitGovernanceVault.sol";

// =====================================================================================================================
// Halmos campaign of the redesigned release. Bounded symbolic properties, one harness per component.
// `check_*` functions run under Halmos; `testFuzz_*` functions run under Forge and only confirm that the few lines
// copied here are the real code. Every copy names the source lines it mirrors.
// =====================================================================================================================

/// @notice Branch-free logic for the checks: each check folds its facts into ONE assertion, so Halmos issues one solver
///         query per path instead of one per `assert` (queries over FullMath's 512-bit terms dominate the running time),
///         and `&&`/`||`/`?:` add no branch. Arithmetic inside an assertion is `unchecked` only where a conjunct of the
///         same assertion bounds every operand: a checked overflow would revert and silently drop the path instead.
abstract contract SymbolicLogic {
    function _all(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(a, b)
        }
    }

    function _or(bool a, bool b) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := or(a, b)
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 1. BandLib.retracementWallTarget — the wall's lower tick for 40% of the current price + 60% of the launch price
// ---------------------------------------------------------------------------------------------------------------------

/// @notice Constants of the canonical pool and the few lines of BandLib copied so that `t` can be made symbolic.
abstract contract RedesignGeometry {
    int24 internal constant SPACING = 10;
    int24 internal constant MIN_USABLE = -887_270; // TickMath.minUsableTick(10)
    int24 internal constant MAX_USABLE = 887_270; // TickMath.maxUsableTick(10)
    int24 internal constant MAX_LOWER = 887_260; // the highest lower tick a one-spacing wall can use
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LAUNCH_ETH = 3.75 ether;
    uint256 internal constant SUPPLY = 21_000_000e18;

    /// @dev CubitHook.INITIAL_SQRT_PRICE of the production launch (3.75 ETH for 21M CUBIT).
    function _launchSqrt() internal pure returns (uint160) {
        return uint160(BandLib.sqrtPriceForRatio(LAUNCH_ETH, SUPPLY));
    }

    /// @dev COPY of BandLib.wallTarget l. 131-132 and 141-143 once `t` is known, with the `spotTick = MIN_TICK`
    ///      that retracementWallTarget passes. ceilToSpacing and maxUsableTick are the real internal functions.
    function _lowerFromTick(int24 t) internal pure returns (int24 lower) {
        int24 maxLower = TickMath.maxUsableTick(SPACING) - SPACING;
        int24 cap = BandLib.ceilToSpacing(TickMath.MIN_TICK + 1, SPACING);
        lower = BandLib.ceilToSpacing(t + 1, SPACING);
        if (lower < cap) lower = cap;
        if (lower > maxLower) lower = maxLower;
    }

    /// @dev COPY of BandLib.wallTarget l. 134-138: the tick at the target's sqrt price, clamped to the TickMath range.
    function _tickOfTarget(uint256 ethE) internal pure returns (int24 t) {
        uint256 sqrtX96 = BandLib.sqrtPriceForRatio(ethE, WAD);
        if (sqrtX96 >= TickMath.MAX_SQRT_PRICE) t = TickMath.MAX_TICK;
        else if (sqrtX96 < TickMath.MIN_SQRT_PRICE) t = TickMath.MIN_TICK;
        else t = TickMath.getTickAtSqrtPrice(uint160(sqrtX96));
    }

    /// @dev COPY of BandLib.retracementWallTarget l. 108: 40% of the current price + 60% of the launch price.
    function _combine(uint256 base, uint256 current) internal pure returns (uint256) {
        return (current * (10_000 - BandLib.WALL_RETRACEMENT_BPS) + base * BandLib.WALL_RETRACEMENT_BPS) / 10_000;
    }

    /// @dev COPY of BandLib.retracementWallTarget l. 106-108 (prices in ETH per CUBIT, WAD).
    function _targetPrice(uint160 launchSqrt, uint160 currentSqrt) internal pure returns (uint256) {
        return _combine(BandLib.ethPerCubitAtSqrt(launchSqrt), BandLib.ethPerCubitAtSqrt(currentSqrt));
    }

    /// @dev A sqrt price inside tick [tick, tick + 1), the tick drawn in [lo, hi - 1].
    function _sqrtInTick(uint256 tickSeed, uint256 frac, int24 lo, int24 hi) internal pure returns (uint160) {
        int24 tick = lo + int24(int256(tickSeed % uint256(int256(hi - lo))));
        uint160 a = TickMath.getSqrtPriceAtTick(tick);
        uint160 b = TickMath.getSqrtPriceAtTick(tick + 1);
        return a + uint160(frac % (b - a));
    }
}

contract RedesignBandLibSymbolic is Test, RedesignGeometry, SymbolicLogic {
    // ------------------------------------------------------------ tick space (the copied orchestration, symbolic t)

    /// @notice Aligned on the spacing, inside the usable ticks, and one spacing wide around t: `t < lower` and
    ///         `lower - spacing <= t`. Only the top clamp can bind (t >= 887 260); the bottom cap never does.
    function check_wallLower_alignedBoundedBracketed(int24 t) public pure {
        vm.assume(t >= TickMath.MIN_TICK && t <= TickMath.MAX_TICK);
        int24 lower = _lowerFromTick(t);
        bool bracket =
            _or(_all(t < MAX_LOWER, _all(t < lower, lower - SPACING <= t)), _all(t >= MAX_LOWER, lower == MAX_LOWER));
        assert(_all(_all(lower % SPACING == 0, lower >= MIN_USABLE), _all(lower <= MAX_LOWER, bracket)));
    }

    /// @notice A higher tick never gives a lower wall tick.
    function check_wallLower_monotone(int24 t1, int24 t2) public pure {
        vm.assume(t1 >= TickMath.MIN_TICK && t1 <= t2 && t2 <= TickMath.MAX_TICK);
        assert(_lowerFromTick(t1) <= _lowerFromTick(t2));
    }

    /// @notice The 40/60 target never decreases when the current price rises and lies between the two prices it
    ///         mixes. Domain: every price below 2^192 wei per CUBIT (ethPerCubitAtSqrt never exceeds 2^188).
    function check_targetCombination_monotoneAndBetween(uint192 base, uint192 c1, uint192 c2) public pure {
        vm.assume(c1 <= c2);
        uint256 x1 = _combine(base, c1);
        bool between = _or(_all(c1 >= base, _all(base <= x1, x1 <= c1)), _all(c1 < base, _all(c1 <= x1, x1 <= base)));
        assert(_all(x1 <= _combine(base, c2), between));
    }

    // ------------------------------------------------------------ real-code lemmas (256-bit nonlinear arithmetic)

    /// @notice ethPerCubitAtSqrt never increases with the sqrt price (a higher pool price is a lower CUBIT price).
    function check_ethPerCubitAtSqrt_antitone(uint160 s1, uint160 s2) public pure {
        vm.assume(s1 >= TickMath.MIN_SQRT_PRICE && s1 <= s2 && s2 < TickMath.MAX_SQRT_PRICE);
        assert(BandLib.ethPerCubitAtSqrt(s1) >= BandLib.ethPerCubitAtSqrt(s2));
    }

    /// @notice Both divisions of ethPerCubitAtSqrt are exact floors: x = floor(1e18·2^96/s), y = floor(x·2^96/s)
    ///         (EVM division is the floor; x < 2^125, so x << 96 loses no bit once the first conjunct holds).
    function check_ethPerCubitAtSqrt_twoFloors(uint160 s) public pure {
        vm.assume(s >= TickMath.MIN_SQRT_PRICE && s < TickMath.MAX_SQRT_PRICE);
        uint256 k = WAD << 96;
        uint256 x = FullMath.mulDiv(WAD, uint256(1) << 96, s);
        uint256 y = BandLib.ethPerCubitAtSqrt(s);
        assert(_all(x == k / s, y == (x << 96) / s));
    }

    /// @notice sqrtPriceForRatio never increases with the ETH amount (any target below 2^192 wei per CUBIT).
    function check_sqrtPriceForRatio_antitone(uint192 e1, uint192 e2) public pure {
        vm.assume(e1 != 0 && e1 <= e2);
        assert(BandLib.sqrtPriceForRatio(e1, WAD) >= BandLib.sqrtPriceForRatio(e2, WAD));
    }

    /// @notice The full real composition on a symbolic current price (production launch price). Expected to exceed
    ///         Halmos: TickMath.getTickAtSqrtPrice calls getSqrtPriceAtTick on a symbolic tick, which branches on
    ///         every bit of it. Run with a wall-clock limit to document the limit, never counted as a proof.
    function check_retracementWallTarget_realCode(uint160 current) public pure {
        vm.assume(current >= TickMath.MIN_SQRT_PRICE && current < TickMath.MAX_SQRT_PRICE);
        int24 lower = BandLib.retracementWallTarget(_launchSqrt(), current, SPACING);
        assert(_all(lower % SPACING == 0, _all(lower >= MIN_USABLE, lower <= MAX_LOWER)));
    }

    // ------------------------------------------------------------ Forge only: exhaustive enumeration of finite domains

    /// @notice Forge, EXHAUSTIVE over every tick (MIN_TICK..MAX_TICK, 1 774 545 values): the copied orchestration gives an
    ///         aligned, bounded, one-spacing bracket, and it is monotone (consecutive ticks suffice on a total order).
    ///         A proof by enumeration of the facts that check_wallLower_* state symbolically.
    function testExhaustive_wallLowerEveryTick() public {
        vm.pauseGasMetering();
        int24 previous = _lowerFromTick(TickMath.MIN_TICK);
        for (int24 t = TickMath.MIN_TICK;; t++) {
            int24 lower = _lowerFromTick(t);
            bool ok = lower % SPACING == 0 && lower >= MIN_USABLE && lower <= MAX_LOWER && lower >= previous;
            ok = ok && (t < MAX_LOWER ? (t < lower && lower - SPACING <= t) : lower == MAX_LOWER);
            if (!ok) revert(string.concat("wallLower fails at tick ", vm.toString(int256(t))));
            previous = lower;
            if (t == TickMath.MAX_TICK) break;
        }
    }

    /// @notice Forge, EXHAUSTIVE over every tick: the real BandLib.floorToSpacing and ceilToSpacing are the exact floor and
    ///         ceiling to the spacing.
    function testExhaustive_floorAndCeilEveryTick() public {
        vm.pauseGasMetering();
        for (int24 t = TickMath.MIN_TICK;; t++) {
            int24 f = BandLib.floorToSpacing(t, SPACING);
            int24 c = BandLib.ceilToSpacing(t, SPACING);
            bool ok = f % SPACING == 0 && f <= t && t - f < SPACING && c % SPACING == 0 && c >= t && c - t < SPACING;
            if (!ok) revert(string.concat("floor/ceil fails at tick ", vm.toString(int256(t))));
            if (t == TickMath.MAX_TICK) break;
        }
    }

    // ------------------------------------------------------------ Forge only: the copies are the real code

    function testFuzz_copiedLinesMatchWallTarget(uint256 ethE) public {
        assertEq(
            int256(_lowerFromTick(_tickOfTarget(ethE))),
            int256(BandLib.wallTarget(ethE, WAD, TickMath.MIN_TICK, SPACING))
        );
    }

    function testFuzz_copiedLinesMatchRetracementWallTarget(uint256 tickSeed, uint256 frac) public {
        uint160 current = _sqrtInTick(tickSeed, frac, TickMath.MIN_TICK, TickMath.MAX_TICK);
        uint160 launch = _launchSqrt();
        assertEq(
            int256(_lowerFromTick(_tickOfTarget(_targetPrice(launch, current)))),
            int256(BandLib.retracementWallTarget(launch, current, SPACING))
        );
    }

    /// @notice The price bracket on the real code with its explicit rounding tolerance:
    ///         price(lower) <= target + target·2^36/sqrt(lower) + 1   (sqrtPriceForRatio keeps 2^32 of granularity)
    ///         price(lower - spacing) + 2^96/sqrt(lower - spacing) + 2 >= target   (the two floors of ethPerCubitAtSqrt)
    function testFuzz_retracementBracket_explicitTolerance(uint256 tickSeed, uint256 frac) public {
        uint160 current = _sqrtInTick(tickSeed, frac, MIN_USABLE, MAX_USABLE);
        uint160 launch = _launchSqrt();
        uint256 target = _targetPrice(launch, current);
        int24 lower = BandLib.retracementWallTarget(launch, current, SPACING);
        assertEq(int256(lower % SPACING), 0);
        assertGe(int256(lower), int256(MIN_USABLE));
        assertLe(int256(lower), int256(MAX_LOWER));
        if (lower > MIN_USABLE && lower < MAX_LOWER) {
            uint160 sTop = TickMath.getSqrtPriceAtTick(lower);
            uint160 sBelow = TickMath.getSqrtPriceAtTick(lower - SPACING);
            assertLe(
                BandLib.ethPerCubitAtSqrt(sTop),
                target + FullMath.mulDiv(target, uint256(1) << 36, sTop) + 1,
                "top tick"
            );
            assertGe(BandLib.ethPerCubitAtSqrt(sBelow) + (uint256(1) << 96) / sBelow + 2, target, "one spacing lower");
        }
    }

    /// @notice A higher current CUBIT price (a lower sqrt price) never gives a lower target price (a higher tick).
    function testFuzz_retracementWallTarget_monotone(uint256 s1, uint256 f1, uint256 s2, uint256 f2) public {
        uint160 a = _sqrtInTick(s1, f1, TickMath.MIN_TICK, TickMath.MAX_TICK);
        uint160 b = _sqrtInTick(s2, f2, TickMath.MIN_TICK, TickMath.MAX_TICK);
        if (a > b) (a, b) = (b, a);
        uint160 launch = _launchSqrt();
        assertLe(
            int256(BandLib.retracementWallTarget(launch, a, SPACING)),
            int256(BandLib.retracementWallTarget(launch, b, SPACING))
        );
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 2. BandLib.liquidityForEth / liquidityForTokens — the real linked library
// ---------------------------------------------------------------------------------------------------------------------

contract RedesignLiquiditySymbolic is Test, SymbolicLogic {
    /// @notice Never spends more than it holds, respects the cap, and a zero liquidity charges nothing. Whole domain.
    function check_liquidityForEth_neverOverspends(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount,
        uint128 maxLiquidity
    ) public pure {
        vm.assume(sqrtLower >= TickMath.MIN_SQRT_PRICE && sqrtLower < sqrtUpper && sqrtUpper <= TickMath.MAX_SQRT_PRICE);
        (uint128 liquidity, uint256 used) = BandLib.liquidityForEth(sqrtLower, sqrtUpper, amount, maxLiquidity);
        assert(_all(used <= amount, _all(liquidity <= maxLiquidity, _or(liquidity != 0, used == 0))));
    }

    function check_liquidityForTokens_neverOverspends(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount,
        uint128 maxLiquidity
    ) public pure {
        vm.assume(sqrtLower >= TickMath.MIN_SQRT_PRICE && sqrtLower < sqrtUpper && sqrtUpper <= TickMath.MAX_SQRT_PRICE);
        (uint128 liquidity, uint256 used) = BandLib.liquidityForTokens(sqrtLower, sqrtUpper, amount, maxLiquidity);
        assert(_all(used <= amount, _all(liquidity <= maxLiquidity, _or(liquidity != 0, used == 0))));
    }

    /// @notice `used` is exactly what v4 charges for the returned liquidity (WallLib.fund relies on this equality).
    function check_liquidityForEth_usedIsTheV4Charge(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount,
        uint128 maxLiquidity
    ) public pure {
        vm.assume(sqrtLower >= TickMath.MIN_SQRT_PRICE && sqrtLower < sqrtUpper && sqrtUpper <= TickMath.MAX_SQRT_PRICE);
        (uint128 liquidity, uint256 used) = BandLib.liquidityForEth(sqrtLower, sqrtUpper, amount, maxLiquidity);
        if (liquidity != 0) assert(used == SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true));
    }

    /// @notice The same three properties on the ranges the hook really uses — a one-spacing wall at the launch tick, at
    ///         both ends of the usable ticks and at a bitmap group boundary — for any amount below 2^128 wei.
    function check_liquidityForEth_hookWallRanges(uint8 which, uint128 amount, uint128 maxLiquidity) public pure {
        (uint160 a, uint160 b) = _wallRange(which);
        (uint128 liquidity, uint256 used) = BandLib.liquidityForEth(a, b, amount, maxLiquidity);
        assert(_all(used <= amount, _all(liquidity <= maxLiquidity, _or(liquidity != 0, used == 0))));
    }

    /// @notice The band [minUsableTick, launch tick], any amount up to the whole supply: the three properties.
    function check_liquidityForTokens_bandRange(uint88 amount, uint128 maxLiquidity) public pure {
        vm.assume(amount <= 21_000_000e18);
        (uint128 liquidity, uint256 used) = BandLib.liquidityForTokens(_bandLower(), _bandUpper(), amount, maxLiquidity);
        assert(_all(used <= amount, _all(liquidity <= maxLiquidity, _or(liquidity != 0, used == 0))));
    }

    /// @notice Liveness (arithmetic): liquidityForEth never reverts on the hook's wall ranges, for any amount below 2^128.
    function check_liveness_liquidityForEthHookWallRanges(uint8 which, uint128 amount, uint128 maxLiquidity)
        public
        view
    {
        (uint160 a, uint160 b) = _wallRange(which);
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.ethFor, (a, b, amount, maxLiquidity)));
        assert(ok);
    }

    /// @notice Liveness (arithmetic): liquidityForTokens never reverts on the band, for any amount up to the supply.
    function check_liveness_liquidityForTokensBand(uint88 amount, uint128 maxLiquidity) public view {
        vm.assume(amount <= 21_000_000e18);
        (bool ok,) =
            address(this).staticcall(abi.encodeCall(this.tokensFor, (_bandLower(), _bandUpper(), amount, maxLiquidity)));
        assert(ok);
    }

    function _wallRange(uint8 which) internal pure returns (uint160, uint160) {
        int24 lower = _wallLower(which);
        return (TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(lower + 10));
    }

    function _bandLower() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(-887_270);
    }

    function _bandUpper() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(155_390);
    }

    /// @notice CANARY (expected counterexample): 1 ETH in the launch-tick wall mints liquidity, so the linked BandLib runs.
    function check_canary_liquidityForEthMints() public pure {
        (uint128 liquidity,) = BandLib.liquidityForEth(
            TickMath.getSqrtPriceAtTick(155_400), TickMath.getSqrtPriceAtTick(155_410), 1 ether, type(uint128).max
        );
        assert(liquidity == 0);
    }

    function ethFor(uint160 a, uint160 b, uint256 amount, uint128 maxLiquidity)
        external
        pure
        returns (uint128, uint256)
    {
        return BandLib.liquidityForEth(a, b, amount, maxLiquidity);
    }

    function tokensFor(uint160 a, uint160 b, uint256 amount, uint128 maxLiquidity)
        external
        pure
        returns (uint128, uint256)
    {
        return BandLib.liquidityForTokens(a, b, amount, maxLiquidity);
    }

    /// @notice STRUCTURAL COPY of the control flow of liquidityForEth/liquidityForTokens (BandLib.sol l. 171-181 and
    ///         191-199) where every rounding result is an ARBITRARY value: the three properties need nothing from
    ///         SqrtPriceMath, only the clamp, the decrement loop and the final reset.
    function check_liquidityLoop_anyRounding(
        uint256 amount,
        uint256 wide,
        uint128 maxLiquidity,
        uint256[6] memory usedAt
    ) public pure {
        if (amount == 0) return; // the real code returns (0, 0)
        uint128 liquidity = wide > maxLiquidity ? maxLiquidity : uint128(wide);
        uint256 k;
        uint256 used = usedAt[k];
        while (used > amount && liquidity > 0) {
            liquidity--;
            k++;
            used = usedAt[k];
        }
        if (liquidity == 0) used = 0;
        assert(_all(used <= amount, _all(liquidity <= maxLiquidity, _or(liquidity != 0, used == 0))));
    }

    function _wallLower(uint8 which) internal pure returns (int24) {
        if (which == 0) return 155_400;
        if (which == 1) return -887_270;
        if (which == 2) return 887_260;
        return -231_920;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3. Hook taxes — pure copies, then the real CubitHook callbacks against the copies
// ---------------------------------------------------------------------------------------------------------------------

abstract contract RedesignTaxCopies is SymbolicLogic {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BUY_TAX_BPS = 300;
    uint256 internal constant SELL_TAX_BPS = 1_500;
    uint256 internal constant SELL_TEAM_BPS = 300;
    uint256 internal constant INT128_MAX = uint256(uint128(type(int128).max));

    /// @dev COPY of CubitHook._inclusiveBuyTax (CubitHook.sol l. 374-378): exact-input buys.
    function _buyExactInTax(uint256 amountIn) internal pure returns (uint256 tax) {
        tax = FullMath.mulDivRoundingUp(amountIn, BUY_TAX_BPS, BPS);
        if (tax > type(uint120).max) tax = type(uint120).max;
        if (tax >= amountIn) tax = amountIn == 0 ? 0 : amountIn - 1;
    }

    /// @dev COPY of CubitHook.afterSwap l. 331-332: exact-output buys, `paid` = the ETH the pool leg took.
    function _buyExactOutTax(uint256 paid) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(paid, BUY_TAX_BPS, BPS - BUY_TAX_BPS);
    }

    /// @dev COPY of CubitHook.afterSwap l. 341-343: exact-input sales, `out` = the gross ETH leaving the pool.
    function _sellExactInTax(uint256 out) internal pure returns (uint256 tax) {
        tax = FullMath.mulDivRoundingUp(out, SELL_TAX_BPS, BPS);
        if (tax > out) tax = out;
    }

    /// @dev COPY of CubitHook.beforeSwap l. 305-307: exact-output sales, `out` = the ETH the seller asks for.
    function _sellExactOutTax(uint256 out) internal pure returns (uint256 tax) {
        tax = FullMath.mulDivRoundingUp(out, SELL_TAX_BPS, BPS - SELL_TAX_BPS);
        if (tax > type(uint120).max) tax = type(uint120).max;
    }

    /// @dev COPY of CubitHook._creditSellTax l. 391-392: the team share rounded down, the rest to the walls.
    function _sellSplit(uint256 tax) internal pure returns (uint256 toTeam, uint256 toFloor) {
        toTeam = tax * SELL_TEAM_BPS / SELL_TAX_BPS;
        toFloor = tax - toTeam;
    }
}

contract RedesignTaxMathSymbolic is Test, RedesignTaxCopies {
    // Amounts are typed uint120/uint128 wherever the domain allows it: structurally zero high bits keep the 512-bit
    // mulmod terms of FullMath small for the solver (a vm.assume bound leaves them as free 256-bit variables).
    // The whole-domain variants keep uint256.

    // Each requested tax property is split in two checks: STRUCTURE (no arithmetic fact needed, whole domain) and
    // ARITHMETIC (ceil identities and ratios, every amount below 2^88 wei ≈ 309 million ETH, more than all the ETH that
    // exists). Division identities over 256-bit words exceed both installed solvers far more often than structure does.

    /// @notice Exact-input buy, arithmetic (every amount from 2 wei to 2^88 wei): at least 1 wei and exactly
    ///         ceil(amount × 3%). The 0 and 1 wei amounts are in check_buyExactIn_belowAmount.
    function check_buyExactIn_ceil(uint88 amount) public pure {
        vm.assume(amount >= 2);
        uint256 amountIn = amount;
        uint256 tax = _buyExactInTax(amountIn);
        bool ok;
        unchecked {
            // no wrap-around: amountIn < 2^88, and the copy's last line keeps tax below amountIn
            ok = _all(tax >= 1, _all(tax * BPS >= amountIn * BUY_TAX_BPS, (tax - 1) * BPS < amountIn * BUY_TAX_BPS));
        }
        assert(ok);
    }

    /// @notice Exact-input buy, structure only, for every amount a swap can specify (up to 2^255 wei): nothing on 0 wei,
    ///         a tax strictly below the amount from 1 wei on (so nothing on 1 wei), never above the uint120 cap.
    function check_buyExactIn_belowAmount(uint256 amountIn) public pure {
        vm.assume(amountIn <= 2 ** 255);
        uint256 tax = _buyExactInTax(amountIn);
        assert(_all(_or(amountIn == 0, tax < amountIn), _all(_or(amountIn != 0, tax == 0), tax <= type(uint120).max)));
    }

    /// @notice Exact-input buy for every amount a swap can specify (up to 2^255 wei): 1 <= tax < amount from 2 wei,
    ///         nothing on 0 or 1 wei, never above the uint120 cap.
    function check_buyExactIn_anyAmount(uint256 amountIn) public pure {
        vm.assume(amountIn <= 2 ** 255);
        uint256 tax = _buyExactInTax(amountIn);
        bool shape = _or(_all(amountIn >= 2, _all(tax >= 1, tax < amountIn)), _all(amountIn < 2, tax == 0));
        assert(_all(shape, tax <= type(uint120).max));
    }

    /// @notice Exact-output buy, arithmetic (every `paid` below 2^88 wei): tax = ceil(paid × 300 / 9 700), i.e. at least
    ///         3% of the gross paid + tax with one wei less below 3%, and it fits the int128 hook delta.
    function check_buyExactOut_ceil(uint88 paidEth) public pure {
        uint256 paid = paidEth;
        uint256 tax = _buyExactOutTax(paid);
        bool ok;
        unchecked {
            // no wrap-around: paid < 2^128, and the last conjunct bounds tax by int128.max
            ok = _all(
                _all(tax * 9_700 >= paid * 300, _or(tax == 0, (tax - 1) * 9_700 < paid * 300)),
                _all(tax * BPS >= (paid + tax) * BUY_TAX_BPS, tax <= INT128_MAX)
            );
        }
        assert(ok);
    }

    /// @notice Exact-input sale, structure (every gross output below 2^128): tax <= out and team + walls = tax.
    function check_sellExactIn_structure(uint128 grossOut) public pure {
        uint256 out = grossOut;
        uint256 tax = _sellExactInTax(out);
        (uint256 toTeam, uint256 toFloor) = _sellSplit(tax);
        assert(_all(tax <= out, toTeam + toFloor == tax));
    }

    /// @notice Exact-input sale, arithmetic (every gross output below 2^88 wei): tax = ceil(out × 15%) and the walls keep
    ///         at least 12/15 of it.
    function check_sellExactIn_ceilAndWallShare(uint88 grossOut) public pure {
        uint256 out = grossOut;
        uint256 tax = _sellExactInTax(out);
        (, uint256 toFloor) = _sellSplit(tax);
        bool ok;
        unchecked {
            // no wrap-around: out < 2^88, and the first conjunct bounds tax by out
            ok = _all(
                _all(tax <= out, tax * BPS >= out * SELL_TAX_BPS),
                _all(_or(tax == 0, (tax - 1) * BPS < out * SELL_TAX_BPS), toFloor * SELL_TAX_BPS >= tax * 1_200)
            );
        }
        assert(ok);
    }

    /// @notice The 12/3 split, structure (ANY tax below 2^128, every tax the hook can book): team = tax × 300 / 1 500
    ///         rounded down, walls = the rest, team + walls = tax.
    function check_sellSplit_structure(uint128 anyTax) public pure {
        uint256 tax = anyTax;
        (uint256 toTeam, uint256 toFloor) = _sellSplit(tax);
        assert(_all(_all(toTeam == tax * 300 / 1_500, toFloor == tax - toTeam), toTeam + toFloor == tax));
    }

    /// @notice The 12/3 split, arithmetic (every tax below 2^88 wei): the walls keep at least 12/15, the team at most 3/15.
    function check_sellSplit_ratios(uint88 anyTax) public pure {
        uint256 tax = anyTax;
        (uint256 toTeam, uint256 toFloor) = _sellSplit(tax);
        assert(_all(toFloor * SELL_TAX_BPS >= tax * 1_200, toTeam * SELL_TAX_BPS <= tax * SELL_TEAM_BPS));
    }

    /// @notice Exact-output sale, arithmetic (every requested amount from 1 wei to 2^88 wei): tax = ceil(out × 1 500 /
    ///         8 500), i.e. 15% of the gross pool output out + tax, below the uint120 cap, and the walls keep >= 12/15.
    function check_sellExactOut_ceil(uint88 requested) public pure {
        vm.assume(requested != 0);
        uint256 out = requested;
        uint256 tax = _sellExactOutTax(out);
        (, uint256 toFloor) = _sellSplit(tax);
        bool ok;
        unchecked {
            // no wrap-around: out < 2^88, and the copy caps tax at uint120.max
            ok = _all(
                _all(tax * 8_500 >= out * 1_500, _or(tax == 0, (tax - 1) * 8_500 < out * 1_500)),
                _all(
                    _all(tax * BPS >= (out + tax) * SELL_TAX_BPS, tax < type(uint120).max),
                    toFloor * SELL_TAX_BPS >= tax * 1_200
                )
            );
        }
        assert(ok);
    }

    /// @notice Exact-output sale for every amount a swap can specify: never above the uint120 cap, and `out + tax` (the
    ///         gross output _creditSellTax books) never overflows.
    function check_sellExactOut_anyAmount(uint256 out) public pure {
        vm.assume(out != 0 && out <= uint256(type(int256).max));
        uint256 tax = _sellExactOutTax(out);
        bool ok;
        unchecked {
            // checked `out + tax` would revert on overflow and drop the path: compare the wrapped sum instead. `>=` states
            // "no overflow" exactly; `>` would also demand tax >= 1, an arithmetic fact that belongs to the ceil checks.
            ok = _all(tax <= type(uint120).max, out + tax >= out);
        }
        assert(ok);
    }

    /// @notice Forge only: the four copies equal independently written ceil formulas (plain uint256 arithmetic, caps
    ///         included) on every uint128 amount the fuzzer draws, and the split of a sale meets its 12/15 and 3/15
    ///         bounds. A concrete cross-check of the arithmetic checks, which Halmos may not close.
    function testFuzz_taxCopiesMatchCeilFormulas(uint128 a) public {
        uint256 x = a;
        uint256 buyIn = (x * 300 + 9_999) / 10_000;
        if (buyIn > type(uint120).max) buyIn = type(uint120).max;
        if (buyIn >= x) buyIn = x == 0 ? 0 : x - 1;
        assertEq(_buyExactInTax(x), buyIn, "exact-input buy");
        assertEq(_buyExactOutTax(x), (x * 300 + 9_699) / 9_700, "exact-output buy");
        uint256 sellIn = (x * 1_500 + 9_999) / 10_000;
        if (sellIn > x) sellIn = x;
        assertEq(_sellExactInTax(x), sellIn, "exact-input sale");
        uint256 sellOut = (x * 1_500 + 8_499) / 8_500;
        if (sellOut > type(uint120).max) sellOut = type(uint120).max;
        assertEq(_sellExactOutTax(x), sellOut, "exact-output sale");
        (uint256 team, uint256 walls) = _sellSplit(sellIn);
        assertEq(team + walls, sellIn, "split sum");
        assertGe(walls * 1_500, sellIn * 1_200, "walls keep 12/15");
        assertLe(team * 1_500, sellIn * 300, "team at most 3/15");
    }
}

/// @notice PoolManager stand-in for the tax paths: the hook mints its ETH claims and reads slot0 through extsload.
contract SymTaxPoolManager {
    bytes32 internal slot0;

    function setSlot0(bytes32 word) external {
        slot0 = word;
    }

    function mint(address, uint256, uint256) external {}

    function extsload(bytes32) external view returns (bytes32) {
        return slot0;
    }
}

/// @notice The REAL CubitHook callbacks return, and book, exactly what the pure copies compute. The hook runs its real
///         creation code at an address carrying its six permission flags (its constructor checks them on address(this)),
///         then the runtime it returns is installed there. No registry (v2 = 0).
contract RedesignHookTaxSymbolic is Test, RedesignTaxCopies {
    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    address internal constant HOOK = address((uint160(0xC0B17) << 16) | FLAGS);
    address internal constant TEAM = address(uint160(0x7EA3));

    SymTaxPoolManager internal manager;
    CubitHook internal hook;
    PoolKey internal key;

    function setUp() public {
        manager = new SymTaxPoolManager();
        CubitToken token = new CubitToken();
        bytes memory creation = abi.encodePacked(
            type(CubitHook).creationCode, abi.encode(address(manager), address(token), TEAM, uint256(3.75 ether))
        );
        vm.etch(HOOK, creation);
        (bool ok, bytes memory runtime) = HOOK.call("");
        require(ok && runtime.length != 0, "hook constructor reverted");
        vm.etch(HOOK, runtime);
        hook = CubitHook(HOOK);
        key = hook.poolKey();
        // slot0 = launch price with tick 887 270, past every wall target: a sale's wall placement is deferred.
        manager.setSlot0(bytes32((uint256(uint24(int24(887_270))) << 160) | uint256(hook.INITIAL_SQRT_PRICE())));
    }

    /// @dev `mustSucceed`: liveness checks assert that the callback does not revert (a reverting callback reverts the
    ///      swap); property checks drop a reverting path instead, its liveness being checked apart.
    function _beforeSwap(bool zeroForOne, int256 amountSpecified, bool mustSucceed) internal returns (uint256) {
        PoolKey memory k = key;
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(hook)
            .call(
                abi.encodeCall(
                    CubitHook.beforeSwap, (address(0), k, SwapParams(zeroForOne, amountSpecified, 0), bytes(""))
                )
            );
        if (mustSucceed) assert(ok);
        else vm.assume(ok);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = abi.decode(ret, (bytes4, BeforeSwapDelta, uint24));
        int128 specified = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
        assert(
            _all(
                _all(selector == IHooks.beforeSwap.selector, fee == 0),
                _all(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta) == 0, specified >= 0)
            )
        );
        return uint256(uint128(specified));
    }

    function _afterSwap(bool zeroForOne, int256 amountSpecified, int128 ethDelta, int128 cubitDelta, bool mustSucceed)
        internal
        returns (uint256)
    {
        PoolKey memory k = key;
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(hook)
            .call(
                abi.encodeCall(
                    CubitHook.afterSwap,
                    (
                        address(0),
                        k,
                        SwapParams(zeroForOne, amountSpecified, 0),
                        toBalanceDelta(ethDelta, cubitDelta),
                        bytes("")
                    )
                )
            );
        if (mustSucceed) assert(ok);
        else vm.assume(ok);
        (bytes4 selector, int128 hookDelta) = abi.decode(ret, (bytes4, int128));
        assert(_all(selector == IHooks.afterSwap.selector, hookDelta >= 0));
        return uint256(uint128(hookDelta));
    }

    /// @notice CANARY (expected counterexample): an exact-input sale runs afterSwap to its end (wall collection and
    ///         placement included) and books a wall share, so the deployed hook and its linked BandLib really execute.
    function check_canary_hookSaleBooksWallShare(int128 ethDelta) public {
        vm.assume(ethDelta > 0);
        _afterSwap(false, -1, ethDelta, 0, false);
        assert(hook.pendingFloorEth() == 0);
    }

    /// @notice Liveness: beforeSwap never reverts, for both directions and every amount the canonical router accepts.
    function check_liveness_hookBeforeSwapNeverReverts(bool zeroForOne, int128 amount) public {
        vm.assume(amount != 0 && amount != type(int128).min);
        _beforeSwap(zeroForOne, amount, true);
    }

    /// @notice Liveness: afterSwap never reverts, for both directions, every accepted amount and every pool delta
    ///         (int128.min excluded: its negation does not fit).
    function check_liveness_hookAfterSwapNeverReverts(
        bool zeroForOne,
        int128 amount,
        int128 ethDelta,
        int128 cubitDelta
    ) public {
        vm.assume(amount != 0 && amount != type(int128).min && ethDelta != type(int128).min);
        _afterSwap(zeroForOne, amount, ethDelta, cubitDelta, true);
    }

    /// @notice Exact-input buy, every amount the canonical router accepts (1 wei to int128.max): the specified delta is
    ///         the copied _inclusiveBuyTax, all of it booked to the team.
    function check_hookBuyExactIn_isTheCopiedTax(uint128 amountIn) public {
        vm.assume(amountIn != 0 && amountIn <= INT128_MAX);
        _hookBuyExactIn(-int256(uint256(amountIn)));
    }

    /// @notice The same on the whole int256 domain another router could specify (a partial fill can succeed).
    function check_hookBuyExactIn_isTheCopiedTax_anyAmount(int256 amountSpecified) public {
        vm.assume(amountSpecified < 0 && amountSpecified != type(int256).min);
        _hookBuyExactIn(amountSpecified);
    }

    function _hookBuyExactIn(int256 amountSpecified) internal {
        uint256 tax = _beforeSwap(true, amountSpecified, false);
        uint256 copy = _buyExactInTax(uint256(-amountSpecified));
        assert(_all(tax == copy, _all(hook.teamAccrued() == tax, hook.pendingFloorEth() == 0)));
    }

    /// @notice Exact-output buy (requested amount 1 to int128.max, any negative ETH delta but int128.min): the afterSwap
    ///         delta is ceil(paid × 300 / 9 700), all of it booked to the team.
    function check_hookBuyExactOut_isTheCopiedTax(uint128 amountOut, int128 ethDelta, int128 cubitDelta) public {
        vm.assume(amountOut != 0 && amountOut <= INT128_MAX && ethDelta < 0 && ethDelta != type(int128).min);
        uint256 tax = _afterSwap(true, int256(uint256(amountOut)), ethDelta, cubitDelta, false);
        uint256 copy = _buyExactOutTax(uint256(uint128(-ethDelta)));
        assert(_all(tax == copy, _all(hook.teamAccrued() == tax, hook.pendingFloorEth() == 0)));
    }

    /// @notice Exact-input sale (amount 1 to int128.max, any positive ETH delta): the afterSwap delta is the copied tax,
    ///         the team and the walls get the copied split.
    function check_hookSellExactIn_isTheCopiedTaxAndSplit(uint128 amountIn, int128 ethDelta, int128 cubitDelta) public {
        vm.assume(amountIn != 0 && amountIn <= INT128_MAX && ethDelta > 0);
        uint256 tax = _afterSwap(false, -int256(uint256(amountIn)), ethDelta, cubitDelta, false);
        uint256 copy = _sellExactInTax(uint256(uint128(ethDelta)));
        (uint256 toTeam, uint256 toFloor) = _sellSplit(tax);
        assert(
            _all(
                _all(tax == copy, hook.teamAccrued() == toTeam),
                _all(hook.pendingFloorEth() == toFloor, hook.activeWallCount() == 0)
            )
        );
    }

    /// @notice Exact-output sale, every amount the canonical router accepts (1 wei to int128.max): the beforeSwap delta
    ///         is the copied tax, the team and the walls get the copied split.
    function check_hookSellExactOut_isTheCopiedTaxAndSplit(uint128 amountOut) public {
        vm.assume(amountOut != 0 && amountOut <= INT128_MAX);
        _hookSellExactOut(int256(uint256(amountOut)));
    }

    /// @notice The same on the whole int256 domain another router could specify.
    function check_hookSellExactOut_isTheCopiedTaxAndSplit_anyAmount(int256 amountSpecified) public {
        vm.assume(amountSpecified > 0);
        _hookSellExactOut(amountSpecified);
    }

    function _hookSellExactOut(int256 amountSpecified) internal {
        uint256 tax = _beforeSwap(false, amountSpecified, false);
        uint256 copy = _sellExactOutTax(uint256(amountSpecified));
        (uint256 toTeam, uint256 toFloor) = _sellSplit(tax);
        assert(_all(tax == copy, _all(hook.teamAccrued() == toTeam, hook.pendingFloorEth() == toFloor)));
    }

    /// @notice Every swap shape pays its tax in exactly one callback: never twice, never skipped (amounts the canonical
    ///         router accepts).
    function check_hookSwap_taxedInExactlyOneCallback(
        bool zeroForOne,
        int128 amount,
        int128 ethDelta,
        int128 cubitDelta
    ) public {
        vm.assume(amount != 0 && amount != type(int128).min && ethDelta != type(int128).min);
        int256 amountSpecified = amount;
        uint256 taxBefore = _beforeSwap(zeroForOne, amountSpecified, false);
        uint256 taxAfter = _afterSwap(zeroForOne, amountSpecified, ethDelta, cubitDelta, false);
        uint256 expected;
        bool inBefore;
        if (zeroForOne) {
            if (amountSpecified < 0) {
                expected = _buyExactInTax(uint256(-amountSpecified));
                inBefore = true;
            } else if (ethDelta < 0) {
                expected = _buyExactOutTax(uint256(uint128(-ethDelta)));
            }
        } else {
            if (amountSpecified > 0) {
                expected = _sellExactOutTax(uint256(amountSpecified));
                inBefore = true;
            } else if (ethDelta > 0) {
                expected = _sellExactInTax(uint256(uint128(ethDelta)));
            }
        }
        bool shape = _or(
            _all(inBefore, _all(taxBefore == expected, taxAfter == 0)),
            _all(!inBefore, _all(taxAfter == expected, taxBefore == 0))
        );
        assert(_all(shape, hook.teamAccrued() + hook.pendingFloorEth() == expected));
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 4. CubitVault.pendingCubit — the real vault, any reachable account state
// ---------------------------------------------------------------------------------------------------------------------

/// @notice Stands in for the hook in CubitVault's constructor, which only reads `token()`.
contract SymVaultHookStub {
    address public token;

    constructor(address token_) {
        token = token_;
    }
}

/// @notice CubitVault unchanged, plus one setter that places an account in any state.
contract CubitVaultHarness is CubitVault {
    constructor(CubitHook hook_) CubitVault(hook_) {}

    function setAccount(address user, uint256 balance, uint256 lastAt, uint256 reserve) external {
        balanceOf[user] = balance;
        lastRewardAt[user] = lastAt;
        rewardReserve = reserve;
    }
}

contract RedesignVaultSymbolic is Test, SymbolicLogic {
    uint256 internal constant SUPPLY = 21_000_000e18; // no balance can exceed the fixed supply
    address internal constant USER = address(uint160(0xA11CE));

    CubitVaultHarness internal vault;
    CubitToken internal token;

    function setUp() public {
        token = new CubitToken();
        vault = new CubitVaultHarness(CubitHook(address(new SymVaultHookStub(address(token)))));
    }

    function _pending() internal view returns (uint256 reward) {
        try vault.pendingCubit(USER) returns (uint256 r) {
            reward = r;
        } catch {
            assert(false); // the view never reverts on a reachable state
        }
    }

    // Property checks call the vault DIRECTLY: a path on which pendingCubit or claimCubit would revert is dropped rather
    // than asserted. Whether they can revert at all (a checked `bal * 300 * elapsed` overflow: nonlinear arithmetic) is
    // stated apart, in check_liveness_*, with try/catch and a low-level call.

    /// @notice Structure: never more than the reserve. Domain of the vault checks: any balance up to the supply, any
    ///         reserve below 2^88, any timestamps below 2^40 (year 36 812).
    function check_pendingCubit_neverAboveReserve(uint88 balance, uint40 lastAt, uint88 reserve, uint40 at) public {
        vm.assume(balance <= SUPPLY && lastAt <= at);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(at);
        assert(vault.pendingCubit(USER) <= reserve);
    }

    /// @notice Structure: constant once one full period (1 day) has elapsed.
    function check_pendingCubit_constantAfterOneDay(uint88 balance, uint40 lastAt, uint88 reserve, uint40 t1, uint40 t2)
        public
    {
        vm.assume(balance <= SUPPLY && uint256(lastAt) + 1 days <= t1 && t1 <= t2);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(t1);
        uint256 r1 = vault.pendingCubit(USER);
        vm.warp(t2);
        assert(r1 == vault.pendingCubit(USER));
    }

    /// @notice Arithmetic: never more than one day's 3% of the stake.
    function check_pendingCubit_atMostThreePercent(uint88 balance, uint40 lastAt, uint88 reserve, uint40 at) public {
        vm.assume(balance <= SUPPLY && lastAt <= at);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(at);
        assert(vault.pendingCubit(USER) <= uint256(balance) * 300 / 10_000);
    }

    /// @notice Arithmetic: non-decreasing with the time elapsed.
    function check_pendingCubit_nonDecreasing(uint88 balance, uint40 lastAt, uint88 reserve, uint40 t1, uint40 t2)
        public
    {
        vm.assume(balance <= SUPPLY && lastAt <= t1 && t1 <= t2);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(t1);
        uint256 r1 = vault.pendingCubit(USER);
        vm.warp(t2);
        assert(r1 <= vault.pendingCubit(USER));
    }

    /// @notice Structure: a claim pays exactly the pending reward out of the reserve, restarts the window and leaves the
    ///         principal.
    function check_claimCubit_paysPendingFromReserve(uint88 balance, uint40 lastAt, uint88 reserve, uint40 at) public {
        vm.assume(balance <= SUPPLY && reserve <= SUPPLY / 2 && lastAt <= at);
        token.transfer(address(vault), reserve);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(at);
        uint256 pending = vault.pendingCubit(USER);
        vm.prank(USER);
        vault.claimCubit();
        // reserve left + paid == reserve (a checked `reserve - pending` would revert and drop the path instead)
        bool paidRight = _all(token.balanceOf(USER) == pending, vault.rewardReserve() + pending == reserve);
        bool booked = _all(vault.totalCubitPaid() == pending, vault.lastRewardAt(USER) == at);
        assert(_all(_all(paidRight, booked), _all(vault.pendingCubit(USER) == 0, vault.balanceOf(USER) == balance)));
    }

    /// @notice Liveness (arithmetic): pendingCubit never reverts on a reachable account state.
    function check_liveness_pendingCubitNeverReverts(uint88 balance, uint40 lastAt, uint88 reserve, uint40 at) public {
        vm.assume(balance <= SUPPLY && lastAt <= at);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(at);
        _pending();
    }

    /// @notice Liveness (arithmetic): a claim never reverts when the vault holds the reserve it books.
    function check_liveness_claimCubitNeverReverts(uint88 balance, uint40 lastAt, uint88 reserve, uint40 at) public {
        vm.assume(balance <= SUPPLY && reserve <= SUPPLY / 2 && lastAt <= at);
        token.transfer(address(vault), reserve);
        vault.setAccount(USER, balance, lastAt, reserve);
        vm.warp(at);
        vm.prank(USER);
        (bool ok,) = address(vault).call(abi.encodeCall(CubitVault.claimCubit, ()));
        assert(ok);
    }

    /// @notice CANARY (expected counterexample): a full day on 1 CUBIT of stake pays something.
    function check_canary_claimPays() public {
        token.transfer(address(vault), 1e18);
        vault.setAccount(USER, 1e18, 0, 1e18);
        vm.warp(1 days);
        vm.prank(USER);
        vault.claimCubit();
        assert(token.balanceOf(USER) == 0);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 5. CubitGovernanceVault — the real vault and a real ERC-20
// ---------------------------------------------------------------------------------------------------------------------

contract RedesignGovernanceVaultSymbolic is Test {
    uint256 internal constant START = 1_000_000;
    uint256 internal constant LOCK = 30 days;
    uint256 internal constant SUPPLY = 21_000_000e18;

    CubitGovernanceVault internal gv;
    CubitToken internal token;

    function setUp() public {
        token = new CubitToken();
        gv = new CubitGovernanceVault(); // deployer = this contract
        token.approve(address(gv), type(uint256).max);
    }

    function _depositThree(uint88[3] memory amounts, uint32[3] memory gaps) internal returns (uint256[3] memory at) {
        for (uint256 i; i < 3; i++) {
            vm.assume(amounts[i] != 0 && amounts[i] <= 7_000_000e18 && gaps[i] <= 400 days);
            at[i] = (i == 0 ? START : at[i - 1]) + gaps[i];
            vm.warp(at[i]);
            (bool ok,) = address(gv).call(abi.encodeCall(CubitGovernanceVault.deposit, (address(token), amounts[i])));
            assert(ok);
        }
    }

    function _claimable() internal view returns (uint256 amount, uint256 count) {
        try gv.claimable(address(token)) returns (uint256 a, uint256 n) {
            (amount, count) = (a, n);
        } catch {
            assert(false);
        }
    }

    /// @notice CANARY (expected counterexample): a tranche is claimable once its 30 days have passed.
    function check_canary_claimAfterUnlock() public {
        vm.warp(START);
        gv.deposit(address(token), 1e18);
        vm.warp(START + LOCK);
        (bool ok,) = _claim(1);
        assert(!ok);
    }

    function _claim(uint256 maxTranches) internal returns (bool ok, uint256 paid) {
        bytes memory ret;
        (ok, ret) = address(gv).call(abi.encodeCall(CubitGovernanceVault.claim, (address(token), maxTranches)));
        if (ok) paid = abi.decode(ret, (uint256));
    }

    /// @notice Three deposits at any times, one claim at any later time with any batch size: `claimable` counts exactly
    ///         the tranches whose date has passed (nothing before the first date) and `claim` pays exactly the oldest of
    ///         them up to the batch size, or reverts when that is nothing.
    function check_claim_paysOnlyMaturedTranches(
        uint88[3] memory amounts,
        uint32[3] memory gaps,
        uint32 wait,
        uint256 maxTranches
    ) public {
        uint256[3] memory at = _depositThree(amounts, gaps);
        vm.assume(wait <= 400 days);
        uint256 claimAt = at[2] + wait;
        vm.warp(claimAt);

        uint256 matured;
        uint256 maturedCount;
        uint256 payable_;
        for (uint256 i; i < 3; i++) {
            if (at[i] + LOCK <= claimAt) {
                matured += amounts[i];
                maturedCount++;
                if (i < maxTranches) payable_ += amounts[i];
            }
        }
        uint256 total = uint256(amounts[0]) + amounts[1] + amounts[2];

        (uint256 claimableAmount, uint256 claimableCount) = _claimable();
        assert(claimableAmount == matured);
        assert(claimableCount == maturedCount);
        if (claimAt < at[0] + LOCK) assert(claimableAmount == 0);

        uint256 before = token.balanceOf(address(this));
        (bool ok, uint256 paid) = _claim(maxTranches);
        if (payable_ == 0) {
            assert(!ok);
            assert(gv.held(address(token)) == total);
        } else {
            assert(ok);
            assert(paid == payable_);
            assert(token.balanceOf(address(this)) - before == payable_);
            assert(gv.held(address(token)) == total - payable_);
        }
        assert(token.balanceOf(address(gv)) == gv.held(address(token)));
    }

    /// @notice Two claims at any two later times with any batch sizes: together they pay exactly the oldest `nextTranche`
    ///         tranches, all of them matured at the second claim, each at most once, and the vault keeps the rest.
    function check_twoClaims_neverPayATrancheTwice(
        uint88[3] memory amounts,
        uint32[3] memory gaps,
        uint32 wait1,
        uint32 wait2,
        uint256 max1,
        uint256 max2
    ) public {
        uint256[3] memory at = _depositThree(amounts, gaps);
        vm.assume(wait1 <= 400 days && wait2 <= 400 days);
        uint256 t2 = at[2] + wait1 + wait2;
        vm.warp(at[2] + wait1);
        (, uint256 paid1) = _claim(max1);
        vm.warp(t2);
        (, uint256 paid2) = _claim(max2);
        uint256 paid = paid1 + paid2;
        uint256 total = uint256(amounts[0]) + amounts[1] + amounts[2];

        uint256 next = gv.nextTranche(address(token));
        uint256 prefix;
        for (uint256 i; i < next; i++) {
            prefix += amounts[i];
            assert(at[i] + LOCK <= t2);
        }
        assert(paid == prefix);
        assert(gv.held(address(token)) == total - paid);
        assert(token.balanceOf(address(gv)) == total - paid);
        assert(token.balanceOf(address(this)) == SUPPLY - total + paid);
    }

    /// @notice Nobody but the deployer can claim, whatever the time.
    function check_claim_onlyDeployer(address caller, uint88 amount, uint32 wait) public {
        vm.assume(caller != address(this) && amount != 0 && amount <= SUPPLY && wait <= 3_650 days);
        vm.warp(START);
        (bool deposited,) = address(gv).call(abi.encodeCall(CubitGovernanceVault.deposit, (address(token), amount)));
        assert(deposited);
        vm.warp(START + wait);
        vm.prank(caller);
        (bool ok,) = address(gv).call(abi.encodeCall(CubitGovernanceVault.claim, (address(token), type(uint256).max)));
        assert(!ok);
        assert(gv.held(address(token)) == amount);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 6. WallLib bitmap — (a) exact copy with symbolic ticks, (b) the real linked library on a bounded tick alphabet
// ---------------------------------------------------------------------------------------------------------------------

/// @notice PoolManager stand-in for WallLib: modifyLiquidity charges what v4 charges a range above the price
///         (getAmount0Delta rounded up, no fees) and a withdrawal returns the range as CUBIT; claims are accepted.
contract SymWallPoolManager {
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory params, bytes calldata)
        external
        pure
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        uint160 a = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 b = TickMath.getSqrtPriceAtTick(params.tickUpper);
        if (params.liquidityDelta > 0) {
            uint256 amount0 = SqrtPriceMath.getAmount0Delta(a, b, uint128(uint256(params.liquidityDelta)), true);
            delta = toBalanceDelta(-int128(int256(amount0)), 0);
        } else {
            uint256 amount1 = SqrtPriceMath.getAmount1Delta(a, b, uint128(uint256(-params.liquidityDelta)), false);
            delta = toBalanceDelta(0, int128(int256(amount1)));
        }
        fees = toBalanceDelta(0, 0);
    }

    function mint(address, uint256, uint256) external {}

    function burn(address, uint256, uint256) external {}
}

/// @notice A real WallLib.Book driven through the real linked WallLib, with the hook's per-position cap.
contract WallBookHarness {
    WallLib.Book internal book;
    IPoolManager internal immutable manager;
    uint128 internal immutable cap;
    PoolKey internal key;

    constructor(IPoolManager manager_) {
        manager = manager_;
        cap = BandLib.maxLiquidityPerTick(10) / 4;
        key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(uint160(0xC0B1))), 100, 10, IHooks(address(this)));
    }

    function fund(int24 lower, uint256 eth) external returns (uint256 used) {
        (used,) = WallLib.fund(book, manager, key, lower, eth, cap);
    }

    function collect(int24 tick) external {
        WallLib.collectCrossed(book, manager, key, tick);
    }

    /// @dev A direct reference to the linked BandLib, so that Halmos deploys BandLib next to WallLib.
    function bandLibLink() external pure returns (uint128 liquidity, uint256 used) {
        return BandLib.liquidityForEth(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, 0, 0);
    }

    function activeLength() external view returns (uint256) {
        return book.active.length;
    }

    function activeAt(uint256 i) external view returns (uint256) {
        return book.active[i];
    }

    function wallCount() external view returns (uint256) {
        return book.walls.length;
    }

    function wall(uint256 id) external view returns (int24 lower, uint128 liquidity, uint32 activeIndex) {
        WallLib.Wall storage w = book.walls[id];
        return (w.lower, w.liquidity, w.activeIndex);
    }

    function nearestTick() external view returns (int24) {
        return book.nearestTick;
    }

    function idPlusOne(int24 lower) external view returns (uint256) {
        return book.idPlusOne[lower];
    }

    function tickWord(uint256 word) external view returns (uint256) {
        return book.tickWords[word];
    }

    function wordGroup(uint256 group) external view returns (uint256) {
        return book.wordGroups[group];
    }

    function groups() external view returns (uint256) {
        return book.groups;
    }
}

/// @notice EXACT copy of WallLib's private bitmap bookkeeping (_removeActive, _addActive, _nearest: WallLib.sol
///         l. 145-185), with the id handling of fund (l. 57-76, 97-98) and of collectCrossed (l. 114-127) around it;
///         liquidity, ETH and PoolManager calls are left out. The function bodies are verbatim; the book is `BookCopy`,
///         WallLib.Book with ONE change: `wordGroups` is a mapping instead of `uint256[3]`, because Halmos 0.3.3 cannot
///         read a static storage array at a symbolic index (its Solidity storage model raises NotConcreteError, and its
///         generic model lets symbolic mapping keys alias the book's fixed slots). The index is always 0, 1 or 2
///         (check_bitmapCopy_groupIndexInRange), where both containers behave identically.
///         Why a copy at all: WallLib only reaches these functions through fund/collectCrossed, which price the wall with
///         TickMath on its tick, and a symbolic tick makes getSqrtPriceAtTick branch on each of its bits.
///         `testFuzz_copyMatchesRealWallLib` replays random sequences on the copy and on the real WallLib and compares
///         them field by field.
contract RedesignWallBitmapSymbolic is Test {
    /// @dev WallLib.Book field for field, except `wordGroups` (see above).
    struct BookCopy {
        WallLib.Wall[] walls;
        uint256[] active;
        mapping(int24 => uint256) idPlusOne;
        uint256 latestId;
        uint256 idleEth;
        int24 nearestTick;
        mapping(uint256 => uint256) tickWords;
        mapping(uint256 => uint256) wordGroups;
        uint256 groups;
    }

    BookCopy internal book;

    // ------------------------------------------------------------ verbatim bodies (WallLib.sol l. 145-185)

    function _removeActive(BookCopy storage b, uint256 id) private {
        uint256 index = b.walls[id].activeIndex - 1;
        uint256 lastId = b.active[b.active.length - 1];
        b.active[index] = lastId;
        b.walls[lastId].activeIndex = uint32(index + 1);
        b.active.pop();
        b.walls[id].activeIndex = 0;
        uint256 bitIndex = uint256(int256(b.walls[id].lower) + 887_270) / 10;
        uint256 word = bitIndex >> 8;
        b.tickWords[word] &= ~(uint256(1) << (bitIndex & 255));
        if (b.tickWords[word] == 0) {
            uint256 group = word >> 8;
            b.wordGroups[group] &= ~(uint256(1) << (word & 255));
            if (b.wordGroups[group] == 0) b.groups &= ~(uint256(1) << group);
        }
        _nearest(b);
    }

    function _addActive(BookCopy storage b, uint256 id) private {
        WallLib.Wall storage w = b.walls[id];
        b.active.push(id);
        w.activeIndex = uint32(b.active.length);
        uint256 bitIndex = uint256(int256(w.lower) + 887_270) / 10;
        uint256 word = bitIndex >> 8;
        uint256 group = word >> 8;
        b.tickWords[word] |= uint256(1) << (bitIndex & 255);
        b.wordGroups[group] |= uint256(1) << (word & 255);
        b.groups |= uint256(1) << group;
        if (b.active.length == 1 || w.lower < b.nearestTick) b.nearestTick = w.lower;
    }

    function _nearest(BookCopy storage b) private {
        if (b.groups == 0) {
            b.nearestTick = type(int24).max;
            return;
        }
        uint256 group = BitMath.leastSignificantBit(b.groups);
        uint256 word = (group << 8) | BitMath.leastSignificantBit(b.wordGroups[group]);
        uint256 bitIndex = (word << 8) | BitMath.leastSignificantBit(b.tickWords[word]);
        b.nearestTick = int24(int256(bitIndex * 10) - 887_270);
    }

    // ------------------------------------------------------------ the callers' id handling (no liquidity)

    /// @dev WallLib.fund l. 57-76 and 97-98: one permanent id per tick, (re)activated when funded.
    function _fund(int24 lower) internal {
        uint256 plusOne = book.idPlusOne[lower];
        uint256 id;
        if (plusOne == 0) {
            id = book.walls.length;
            book.idPlusOne[lower] = id + 1;
            book.walls.push(WallLib.Wall(lower, 0, 0, 0, 0));
        } else {
            id = plusOne - 1;
        }
        WallLib.Wall storage w = book.walls[id];
        if (w.activeIndex == 0) _addActive(book, id);
        book.latestId = id;
    }

    /// @dev One iteration of WallLib.collectCrossed l. 115-127: empties the nearest wall.
    function _collectNearest() internal {
        uint256 id = book.idPlusOne[book.nearestTick] - 1;
        book.walls[id].liquidity = 0;
        _removeActive(book, id);
    }

    /// @dev WallLib.collectCrossed l. 114.
    function _collectCrossed(int24 tick) internal {
        while (book.active.length != 0 && tick >= book.nearestTick + 10) _collectNearest();
    }

    // ------------------------------------------------------------ the invariant, as one final assertion

    function _nz(uint256 x) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := iszero(iszero(x))
        }
    }

    function _ne(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := iszero(eq(a, b))
        }
    }

    function _lt24(int24 a, int24 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := slt(signextend(2, a), signextend(2, b))
        }
    }

    function _eq24(int24 a, int24 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := eq(signextend(2, a), signextend(2, b))
        }
    }

    /// @dev nearestTick = minimum active tick (sentinel once the book is empty again), every active entry points back
    ///      to its index, idPlusOne is consistent, and the three bitmap levels match the set of active walls.
    function _assertBook() internal view {
        uint256 bad;
        uint256 n = book.active.length;
        if (n == 0) {
            // A pristine Book has Solidity's zero-initialized tick. _nearest sets the
            // sentinel only after the last funded wall is removed; collecting an empty
            // book does not call it. Check each state exactly, without skipping empty books.
            int24 expected = book.walls.length == 0 ? int24(0) : type(int24).max;
            bad |= _ne(uint256(int256(book.nearestTick)), uint256(int256(expected)));
            bad |= _nz(book.groups);
        } else {
            uint256 hit;
            for (uint256 i; i < n; i++) {
                WallLib.Wall storage w = book.walls[book.active[i]];
                bad |= _ne(w.activeIndex, i + 1);
                bad |= _lt24(w.lower, book.nearestTick);
                hit |= _eq24(w.lower, book.nearestTick);
            }
            bad |= 1 - hit;
        }
        for (uint256 id; id < book.walls.length; id++) {
            WallLib.Wall storage w = book.walls[id];
            uint256 bitIndex = uint256(int256(w.lower) + 887_270) / 10;
            uint256 word = bitIndex >> 8;
            uint256 group = word >> 8;
            uint256 isActive = w.activeIndex == 0 ? 0 : 1;
            bad |= _ne((book.tickWords[word] >> (bitIndex & 255)) & 1, isActive);
            bad |= _ne((book.wordGroups[group] >> (word & 255)) & 1, _nz(book.tickWords[word]));
            bad |= _ne((book.groups >> group) & 1, _nz(book.wordGroups[group]));
            bad |= _ne(book.idPlusOne[w.lower], id + 1);
            if (isActive == 1) bad |= _ne(book.active[w.activeIndex - 1], id);
        }
        assert(bad == 0);
    }

    function _tick(uint256 u) internal pure returns (int24) {
        return int24(int256(u) * 10 - 887_270);
    }

    /// @notice Every usable one-spacing wall (lower tick in [-887 270, 887 260], aligned) maps to bit index u, word <= 693
    ///         and group <= 2: WallLib's static `uint256[3] wordGroups` is never indexed out of bounds, and the mapping of
    ///         BookCopy behaves the same on these indices.
    function check_bitmapCopy_groupIndexInRange(uint24 u) public pure {
        vm.assume(u <= 177_453);
        int24 lower = _tick(u);
        uint256 bitIndex = uint256(int256(lower) + 887_270) / 10;
        uint256 word = bitIndex >> 8;
        uint256 group = word >> 8;
        assert(bitIndex == u);
        assert(word <= 693);
        assert(group < 3);
    }

    /// @dev fund any usable tick (new or known), empty the nearest wall, or remove any active wall.
    function _step(uint256 u, uint256 op, uint256 pick) internal {
        vm.assume(u <= 177_453);
        uint256 n = book.active.length;
        uint256 kind = op % 3;
        if (kind == 0 || n == 0) {
            _fund(_tick(u));
        } else if (kind == 1) {
            _collectNearest();
        } else {
            uint256 p = pick % n;
            uint256 id;
            if (p == 0) id = book.active[0];
            else if (p == 1) id = book.active[1];
            else if (p == 2) id = book.active[2];
            else if (p == 3) id = book.active[3];
            else id = book.active[4];
            _removeActive(book, id);
        }
        _assertBook();
    }

    /// @notice CANARY (expected counterexample): after funding any tick, the nearest tick is that tick.
    function check_canary_bitmapCopyTracksAFundedTick(uint24 u) public {
        vm.assume(u <= 177_453);
        _fund(_tick(u));
        assert(book.nearestTick != _tick(u));
    }

    /// @notice Three symbolic operations on any usable ticks (the first one funds a wall). Index, operation and pick are
    ///         typed as narrowly as their ranges allow (uint24, uint8), which keeps the solver's terms small.
    function check_bitmapCopy_threeOps(uint24[3] memory ticks, uint8[3] memory ops, uint8[3] memory picks) public {
        for (uint256 i; i < 3; i++) {
            _step(ticks[i], i == 0 ? 0 : ops[i], picks[i]);
        }
    }

    /// @notice Five symbolic operations on any usable ticks (the first one funds a wall).
    function check_bitmapCopy_fiveOps(uint24[5] memory ticks, uint8[5] memory ops, uint8[5] memory picks) public {
        for (uint256 i; i < 5; i++) {
            _step(ticks[i], i == 0 ? 0 : ops[i], picks[i]);
        }
    }

    // ------------------------------------------------------------ Forge only: exhaustive enumeration

    /// @notice Forge, EXHAUSTIVE over every usable one-spacing wall (177 454 lower ticks): the tick is aligned and maps to
    ///         bit index u, word <= 693 and group <= 2. The facts of check_bitmapCopy_groupIndexInRange, by enumeration.
    function testExhaustive_groupIndexEveryWallTick() public {
        vm.pauseGasMetering();
        for (uint256 u; u <= 177_453; u++) {
            int24 lower = _tick(u);
            uint256 bitIndex = uint256(int256(lower) + 887_270) / 10;
            uint256 word = bitIndex >> 8;
            uint256 group = word >> 8;
            if (bitIndex != u || word > 693 || group >= 3 || lower % 10 != 0) {
                revert(string.concat("group index fails at u ", vm.toString(u)));
            }
        }
        assertEq(int256(_tick(0)), int256(-887_270));
        assertEq(int256(_tick(177_453)), int256(887_260));
    }

    // ------------------------------------------------------------ Forge only: the copy is the real WallLib

    function test_emptyBookBeforeFundingAndAfterCollection() public {
        WallBookHarness real = new WallBookHarness(IPoolManager(address(new SymWallPoolManager())));
        real.collect(60_010);
        _collectCrossed(60_010);
        assertEq(int256(real.nearestTick()), 0);
        _assertBook();
        assertGt(real.fund(60_000, 1 ether), 0);
        _fund(60_000);
        real.collect(60_010);
        _collectCrossed(60_010);
        assertEq(real.activeLength(), 0);
        assertEq(real.wallCount(), 1);
        assertEq(int256(real.nearestTick()), int256(type(int24).max));
        _assertBook();
    }

    function testFuzz_copyMatchesRealWallLib(uint256 seed) public {
        WallBookHarness real = new WallBookHarness(IPoolManager(address(new SymWallPoolManager())));
        for (uint256 step; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            // 16 ticks per run, so that walls merge and come back; [-400 000, 887 260] always mints liquidity for 1 ETH.
            uint256 slot = uint256(keccak256(abi.encode(seed, r % 16)));
            int24 lower = int24(-400_000 + int256(slot % 128_727) * 10);
            if (r % 3 != 0) {
                if (real.fund(lower, 1 ether) != 0) _fund(lower);
            } else {
                real.collect(lower);
                _collectCrossed(lower);
            }
            assertEq(real.activeLength(), book.active.length);
            assertEq(real.wallCount(), book.walls.length);
            assertEq(int256(real.nearestTick()), int256(book.nearestTick));
            assertEq(real.groups(), book.groups);
            for (uint256 g; g < 3; g++) {
                assertEq(real.wordGroup(g), book.wordGroups[g]);
            }
            for (uint256 i; i < book.active.length; i++) {
                assertEq(real.activeAt(i), book.active[i]);
            }
            for (uint256 id; id < book.walls.length; id++) {
                (int24 wl,, uint32 activeIndex) = real.wall(id);
                assertEq(int256(wl), int256(book.walls[id].lower));
                assertEq(uint256(activeIndex), uint256(book.walls[id].activeIndex));
                assertEq(
                    real.tickWord((uint256(int256(wl) + 887_270) / 10) >> 8),
                    book.tickWords[(uint256(int256(wl) + 887_270) / 10) >> 8]
                );
            }
            _assertBook();
        }
    }
}

/// @notice The REAL linked WallLib (fund / collectCrossed and their private bitmap functions) on every sequence of three
///         operations under Halmos, and of five under Forge (exhaustive depth-first enumeration with state snapshots),
///         over ticks on both sides of the group 0|1 (bit 65 535|65 536) and group 1|2 (131 071|131 072) boundaries of
///         the three-level bitmap, compared with a shadow set of active ticks.
contract RedesignWallLibBoundedSymbolic is Test {
    WallBookHarness internal h;

    function setUp() public {
        h = new WallBookHarness(IPoolManager(address(new SymWallPoolManager())));
    }

    function _alphabet(uint256 c) internal pure returns (int24) {
        if (c == 0) return -231_920;
        if (c == 1) return -231_910;
        if (c == 2) return 423_440;
        return 423_450;
    }

    function _fundOk(int24 t) internal returns (uint256 used) {
        (bool ok, bytes memory ret) = address(h).call(abi.encodeCall(WallBookHarness.fund, (t, 1 ether)));
        assert(ok); // a funding that reverts would revert the sale that places it
        used = abi.decode(ret, (uint256));
    }

    function _collectOk(int24 t) internal {
        (bool ok,) = address(h).call(abi.encodeCall(WallBookHarness.collect, (t)));
        assert(ok); // a collection that reverts would revert the sale that crosses the walls
    }

    /// @notice CANARY (expected counterexample): funding a wall through the real linked WallLib activates it.
    function check_canary_realFundActivates() public {
        _fundOk(_alphabet(0));
        assert(h.activeLength() == 0);
    }

    function _apply(uint256 code, bool[4] memory shadow) internal {
        uint256 c = code % 8;
        if (c < 4) {
            if (_fundOk(_alphabet(c)) != 0) shadow[c] = true;
        } else {
            int24 crossing = _alphabet(c - 4) + 10;
            _collectOk(crossing);
            for (uint256 k; k < 4; k++) {
                if (_alphabet(k) + 10 <= crossing) shadow[k] = false;
            }
        }
        _assertMatchesShadow(shadow);
    }

    function _assertMatchesShadow(bool[4] memory shadow) internal view {
        uint256 count;
        int24 minTick = type(int24).max;
        for (uint256 k; k < 4; k++) {
            int24 t = _alphabet(k);
            if (shadow[k]) {
                count++;
                if (t < minTick) minTick = t;
            }
            uint256 plusOne = h.idPlusOne(t);
            if (plusOne == 0) {
                assert(!shadow[k]);
            } else {
                (int24 wl,, uint32 activeIndex) = h.wall(plusOne - 1);
                assert(wl == t);
                assert((activeIndex != 0) == shadow[k]);
                if (activeIndex != 0) assert(h.activeAt(activeIndex - 1) == plusOne - 1);
            }
        }
        assert(h.activeLength() == count);
        if (count != 0) {
            assert(h.nearestTick() == minTick);
        } else {
            // the sentinel once the book has been emptied; zero before any wall was ever funded
            assert(h.nearestTick() == type(int24).max || h.wallCount() == 0);
            assert(h.groups() == 0);
        }
    }

    /// @notice Every sequence of three operations among the eight (fund one of the four ticks, or cross up to one of them),
    ///         8^3 = 512 sequences. Halmos interprets the real WallLib and TickMath opcode by opcode: four operations (4 096
    ///         sequences) exceeded a 40-minute budget, hence three here and five under Forge.
    function check_realWallLib_threeOps(uint8 op1, uint8 op2, uint8 op3) public {
        bool[4] memory shadow;
        _apply(op1, shadow);
        _apply(op2, shadow);
        _apply(op3, shadow);
    }

    /// @notice Forge, EXHAUSTIVE: every sequence of five operations (8^5 = 32 768 sequences) on the real linked WallLib,
    ///         enumerated depth first with state snapshots (37 448 operations), every intermediate state checked against
    ///         the shadow set, and no fund or collect ever reverting.
    function testExhaustive_realWallLibFiveOps() public {
        vm.pauseGasMetering();
        bool[4] memory shadow;
        _explore(shadow, 5);
    }

    function _explore(bool[4] memory shadow, uint256 depth) internal {
        if (depth == 0) return;
        for (uint256 code; code < 8; code++) {
            uint256 snapshot = vm.snapshotState();
            bool[4] memory next = [shadow[0], shadow[1], shadow[2], shadow[3]];
            _apply(code, next);
            _explore(next, depth - 1);
            vm.revertToStateAndDelete(snapshot);
        }
    }
}
