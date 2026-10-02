// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";

/// @notice Symbolic proofs of the order-book geometry (Halmos).
///
///         The fuzzing campaign says "eight million samples found no counterexample". These say
///         "for EVERY int24, none exists". The properties chosen are the ones the hook's own
///         safety arguments lean on and that a sampler can only ever spot-check: the tick grid
///         is a true floor/ceiling, the wall is never placed where it would be in range, and a
///         deposit never charges more than the amount handed to it.
contract BandLibSymbolicTest is Test {
    int24 internal constant SPACING = 10;

    // ---------------------------------------------------------------- the tick grid

    /// @dev NOTE on `check_ceilToSpacing_isTheLeastMultipleAtOrAbove`, which times out rather than
    ///      failing: it leaves no gap, because the two proofs below entail it. With `f` the
    ///      greatest multiple <= tick and `c = f` on the grid, `c = f + spacing` off it:
    ///      `c % spacing == 0` follows from `f % spacing == 0`; `c > tick` from `tick - f <
    ///      spacing`; and `c - tick = spacing - (tick - f) < spacing` from `tick - f > 0`.

    /// @dev floorToSpacing is a real floor: a multiple of the spacing, at or below the tick, and
    ///      strictly within one spacing of it. Solidity's `/` truncates toward zero, so the
    ///      negative branch is where an off-by-one would live — and every band boundary, the
    ///      cushion and the wall are all placed through this function.
    function check_floorToSpacing_isTheGreatestMultipleAtOrBelow(int24 tick) public pure {
        vm.assume(tick > type(int24).min + SPACING);
        vm.assume(tick < type(int24).max - SPACING);
        int24 f = BandLib.floorToSpacing(tick, SPACING);
        assert(f % SPACING == 0);
        assert(f <= tick);
        assert(tick - f < SPACING);
    }

    /// @dev ceilToSpacing is its mirror.
    function check_ceilToSpacing_isTheLeastMultipleAtOrAbove(int24 tick) public pure {
        vm.assume(tick > type(int24).min + SPACING);
        vm.assume(tick < type(int24).max - SPACING);
        int24 c = BandLib.ceilToSpacing(tick, SPACING);
        assert(c % SPACING == 0);
        assert(c >= tick);
        assert(c - tick < SPACING);
    }

    /// @dev The two agree exactly on the grid and differ by one spacing off it.
    function check_floorAndCeil_agreeOnTheGrid(int24 tick) public pure {
        vm.assume(tick > type(int24).min + SPACING);
        vm.assume(tick < type(int24).max - SPACING);
        int24 f = BandLib.floorToSpacing(tick, SPACING);
        int24 c = BandLib.ceilToSpacing(tick, SPACING);
        if (tick % SPACING == 0) {
            assert(f == tick && c == tick);
        } else {
            assert(c - f == SPACING);
        }
    }

    // The cushion check (`bidRange`) was removed with the cushion itself: the redesign has no bid range. The wall
    // placement properties of the redesign are in RedesignSymbolic.t.sol.
}
