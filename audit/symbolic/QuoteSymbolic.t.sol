// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {QuoteBandLib} from "../../src/quote/QuoteBandLib.sol";

// =====================================================================================================================
// Halmos campaign of the launchpad v2. The only new arithmetic of
// the v2 is QuoteBandLib: prices at 1e36, the 40/60 and 1% wall targets computed from them, and the launch bounds. The
// tax and split code of CubitQuoteHook is CubitHook's, unchanged, and QuoteWallLib
// differs from WallLib only by the ERC-6909 id of the quote. `check_*` functions run under Halmos:
//   FOUNDRY_TEST=audit/symbolic halmos --contract QuoteSymbolic --solver z3
// A revert inside a check is not a counterexample under Halmos, so "never reverts" is checked through a self-call.
// =====================================================================================================================

contract QuoteSymbolic is Test {
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

    function _inRange(uint160 s) internal pure returns (bool) {
        return s >= TickMath.MIN_SQRT_PRICE && s < TickMath.MAX_SQRT_PRICE;
    }

    /// Prices at 1e36 never overflow over the whole sqrt price range.
    function check_priceAtSqrt_neverReverts(uint160 s) public view {
        vm.assume(_inRange(s));
        try this.priceAt(s) returns (uint256) {} catch { assert(false); }
    }

    /// A higher pool price (more tokens per quote unit) is a lower token price.
    function check_priceAtSqrt_isDecreasing(uint160 a, uint160 b) public pure {
        vm.assume(_inRange(a) && _inRange(b) && a < b);
        assert(QuoteBandLib.priceAtSqrt(a) >= QuoteBandLib.priceAtSqrt(b));
    }

    /// The 40/60 target never reverts, whatever the launch and current prices: a sale is never blocked by it.
    function check_retracementTarget_neverReverts(uint160 launch, uint160 current) public view {
        vm.assume(_inRange(launch) && _inRange(current));
        try this.retracement(launch, current) returns (int24) {} catch { assert(false); }
    }

    /// The 1% target never reverts either.
    function check_underMarketTarget_neverReverts(uint160 current) public view {
        vm.assume(_inRange(current));
        try this.underMarket(current) returns (int24) {} catch { assert(false); }
    }

    /// Both targets lie on the spacing grid and leave room for one spacing under the top of the tick range.
    function check_targets_onGridAndInRange(uint160 launch, uint160 current) public pure {
        vm.assume(_inRange(launch) && _inRange(current));
        int24 maxLower = TickMath.maxUsableTick(SPACING) - SPACING;
        int24 r = QuoteBandLib.retracementWallTarget(launch, current, SPACING);
        int24 u = QuoteBandLib.underMarketWallTarget(current, SPACING);
        assert(r % SPACING == 0 && u % SPACING == 0 && r <= maxLower && u <= maxLower);
    }

    /// An accepted launch value opens inside the price range and inside the launch tick bounds.
    function check_launchSqrtPrice_bounds(uint256 value) public pure {
        (bool ok, uint160 s) = QuoteBandLib.launchSqrtPrice(value, 21_000_000e18);
        if (!ok) return;
        assert(value != 0 && _inRange(s));
        int24 tick = TickMath.getTickAtSqrtPrice(s);
        assert(tick >= QuoteBandLib.MIN_LAUNCH_TICK && tick <= QuoteBandLib.MAX_LAUNCH_TICK);
    }
}
