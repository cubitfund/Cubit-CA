// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {QuoteBandLib} from "../../src/quote/QuoteBandLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice The QuoteBandLib properties of audit/symbolic/QuoteSymbolic.t.sol, fuzzed: Halmos times out on their
///         512-bit arithmetic. Inputs are drawn over the whole sqrt price
///         range, through ticks so that extreme prices are as likely as ordinary ones.
///         Large runs: FOUNDRY_FUZZ_RUNS=1000000 forge test --mc QuoteBandLibFuzz
contract QuoteBandLibFuzz is Test {
    int24 internal constant SPACING = 10;

    function priceAt(uint160 s) external pure returns (uint256) {
        return QuoteBandLib.priceAtSqrt(s);
    }

    function retracement(uint160 launch, uint160 current) external pure returns (int24) {
        return QuoteBandLib.retracementWallTarget(launch, current, SPACING);
    }

    function underMarket(uint160 current) external pure returns (int24) {
        return QuoteBandLib.underMarketWallTarget(current, SPACING);
    }

    /// @dev A sqrt price anywhere in range: a random tick, then a random point inside that tick.
    function _sqrt(uint256 seed) internal pure returns (uint160) {
        int24 tick = int24(int256(bound(seed, 0, uint256(int256(TickMath.MAX_TICK) * 2 - 1))) - TickMath.MAX_TICK);
        uint160 low = TickMath.getSqrtPriceAtTick(tick);
        uint160 high = TickMath.getSqrtPriceAtTick(tick + 1);
        return uint160(bound(uint256(keccak256(abi.encode(seed))), low, high - 1));
    }

    function testFuzz_priceAtSqrt_neverReverts(uint256 seed) public view {
        this.priceAt(_sqrt(seed));
    }

    function testFuzz_priceAtSqrt_isDecreasing(uint256 a, uint256 b) public pure {
        (uint160 x, uint160 y) = (_sqrt(a), _sqrt(b));
        if (x > y) (x, y) = (y, x);
        assertGe(QuoteBandLib.priceAtSqrt(x), QuoteBandLib.priceAtSqrt(y));
    }

    function testFuzz_targets_neverRevert_onGrid_inRange(uint256 a, uint256 b) public view {
        (uint160 launch, uint160 current) = (_sqrt(a), _sqrt(b));
        int24 r = this.retracement(launch, current);
        int24 u = this.underMarket(current);
        int24 maxLower = TickMath.maxUsableTick(SPACING) - SPACING;
        assertEq(r % SPACING, 0);
        assertEq(u % SPACING, 0);
        assertLe(r, maxLower);
        assertLe(u, maxLower);
    }

    /// @dev Where there is room, the 1% wall's price is under 99% of the current price, up to the rounding of the
    ///      integer square root in BandLib.sqrtPriceForRatio, and within two spacings of it. That rounding is about
    ///      2/sqrt(ratio) with ratio = 1e36 * 2^128 / target: under 1e-12 around any accepted launch price, 3e-6 at
    ///      tick -638,000, and over one spacing (0.1%) past tick -761,000. The library does not compare
    ///      its target with the current tick (it passes MIN_TICK): the hook does, and leaves the funds pending when
    ///      the target is not above it, so no wall is ever placed in range.
    function testFuzz_underMarketTarget_isOnePercentUnder(uint256 seed) public pure {
        uint160 current = _sqrt(seed);
        int24 u = QuoteBandLib.underMarketWallTarget(current, SPACING);
        (int24 tick) = TickMath.getTickAtSqrtPrice(current);
        vm.assume(u > tick + 2 * SPACING && u < TickMath.maxUsableTick(SPACING) - SPACING);
        uint256 price = QuoteBandLib.priceAtSqrt(current);
        uint256 wallPrice = QuoteBandLib.priceAtSqrt(TickMath.getSqrtPriceAtTick(u));
        vm.assume(price > 1e12); // enough digits for the 0.2% comparison
        uint256 target = FullMath.mulDiv(price, 9_900, 10_000);
        uint256 root = Math.sqrt((uint256(1e36) << 128) / target);
        vm.assume(root > 1_000); // below, the rounding alone exceeds a spacing: see the note above
        assertLe(wallPrice, target + FullMath.mulDiv(target, 4, root), "closer than 1% beyond the square root's rounding");
        assertGe(wallPrice, FullMath.mulDiv(target, 9_980, 10_000), "more than two spacings under 1%");
    }

    function testFuzz_launchSqrtPrice_bounds(uint256 value) public pure {
        (bool ok, uint160 s) = QuoteBandLib.launchSqrtPrice(value, 21_000_000e18);
        if (!ok) return;
        assertTrue(value != 0 && s >= TickMath.MIN_SQRT_PRICE && s < TickMath.MAX_SQRT_PRICE);
        int24 tick = TickMath.getTickAtSqrtPrice(s);
        assertGe(tick, QuoteBandLib.MIN_LAUNCH_TICK);
        assertLe(tick, QuoteBandLib.MAX_LAUNCH_TICK);
    }
}
