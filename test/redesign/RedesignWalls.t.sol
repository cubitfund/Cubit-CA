// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";

/// @notice Walls placed by sales: one wall per sale at the 40/60 target of the price after the sale, merged per tick,
///         never moved; a wall the price only entered stays; every fully crossed wall is emptied by the sale that
///         crossed it, however many, and its CUBIT reach the vault reserve; at or below launch the wall goes 1% under the price.
contract RedesignWallsTest is RedesignBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function testFuzz_saleWallBracketsTheTarget(uint256 ethIn, uint256 bps) public {
        ethIn = bound(ethIn, 0.05 ether, 30 ether);
        uint256 bought = _buy(alice, ethIn);
        uint256 amount = bought * bound(bps, 1, 9_000) / 10_000;
        vm.assume(amount != 0);
        _sell(alice, amount);
        vm.assume(hook.activeWallCount() == 1); // an amount too small to mint liquidity stays pending
        (int24 lower, uint128 liquidity,,) = hook.walls(hook.latestWallId());
        uint160 sqrtP = _sqrtP();
        uint256 target = _targetPrice(sqrtP);
        assertGt(liquidity, 0);
        assertLt(_tick(), lower, "the wall is not strictly above the market");
        assertEq(lower % hook.TICK_SPACING(), 0, "misaligned wall");
        assertLe(BandLib.ethPerCubitAtTick(lower), target, "the wall's top price exceeds the target");
        assertGe(
            BandLib.ethPerCubitAtTick(lower - hook.TICK_SPACING()) * 1_000_001 / 1_000_000,
            target,
            "the wall sits more than one spacing below the target"
        );
        assertEq(lower, BandLib.retracementWallTarget(hook.INITIAL_SQRT_PRICE(), sqrtP, hook.TICK_SPACING()));
        _assertBooks();
    }

    function testFuzz_wallsMergePerTickAndNeverMove(uint256 seed) public {
        _buy(alice, 5 ether);
        int24[] memory seen = new int24[](64);
        uint256 seenCount;
        for (uint256 i; i < 16; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 3 == 0) {
                _buy(bob, 0.01 ether + r % 0.3 ether);
            } else {
                uint256 amount = token.balanceOf(alice) * (1 + r % 400) / 10_000;
                if (amount != 0) _sell(alice, amount);
            }
            for (uint256 id = seenCount; id < hook.wallCount(); id++) {
                (seen[id],,,) = hook.walls(id);
            }
            seenCount = hook.wallCount();
            for (uint256 id; id < seenCount; id++) {
                (int24 lower,,,) = hook.walls(id);
                assertEq(lower, seen[id], "a wall moved");
            }
        }
        uint256 n = hook.activeWallCount();
        for (uint256 i; i < n; i++) {
            (int24 a,,,) = hook.walls(hook.activeWallId(i));
            for (uint256 j = i + 1; j < n; j++) {
                (int24 b,,,) = hook.walls(hook.activeWallId(j));
                assertTrue(a != b, "two active walls share a tick");
            }
        }
        _assertBooks();
        _assertNoCrossedWall();
    }

    function testFuzz_enteredWallStaysAndRefills(uint256 ethIn, uint256 depth) public {
        ethIn = bound(ethIn, 0.2 ether, 10 ether);
        uint256 bought = _buy(alice, ethIn);
        _sell(alice, bought / 5);
        vm.assume(hook.activeWallCount() == 1);
        uint256 id = hook.latestWallId();
        (int24 lower, uint128 liquidity,,) = hook.walls(id);
        int24 spacing = hook.TICK_SPACING();
        (uint256 eth0,) = BandLib.amountsForLiquidity(_sqrtP(), lower, lower + spacing, liquidity);
        _giveReserveCubit(alice, 1_000_000e18);
        int24 inside = lower + int24(int256(bound(depth, 1, uint256(int256(spacing)) - 1)));
        _rawSell(alice, token.balanceOf(alice), TickMath.getSqrtPriceAtTick(inside));
        int24 tick = _tick();
        assertTrue(tick >= lower && tick < lower + spacing, "the sale did not stop inside the wall");
        (, uint128 liquidity1,,) = hook.walls(id);
        (, uint256 cubitInside) = BandLib.amountsForLiquidity(_sqrtP(), lower, lower + spacing, liquidity1);
        assertEq(liquidity1, liquidity, "an entered wall was touched");
        assertGt(cubitInside, 0, "the entered wall holds no CUBIT");
        assertEq(hook.pendingAbsorbedTokens(), 0, "an entered wall was emptied");

        _buy(bob, ethIn);
        assertLt(_tick(), lower, "the buy did not come back above the wall");
        (uint256 eth2, uint256 cubit2) = BandLib.amountsForLiquidity(_sqrtP(), lower, lower + spacing, liquidity);
        assertEq(cubit2, 0);
        assertApproxEqAbs(eth2, eth0, 1, "the wall did not refill with its ETH");
        _assertBooks();
    }

    /// No per-sale cap: 150 walls, one sale through all of them, every one emptied, every CUBIT delivered.
    function test_oneSaleEmptiesEveryCrossedWall() public {
        for (uint256 i; hook.activeWallCount() < 150; i++) {
            require(i < 600, "cycles stopped placing distinct walls");
            uint256 got = _buy(alice, 0.02 ether);
            _sell(alice, got / 10);
        }
        uint256[] memory ids = new uint256[](150);
        for (uint256 i; i < 150; i++) ids[i] = hook.activeWallId(i);
        (,, int24 highest) = _wallSpan();
        _giveReserveCubit(alice, 4_000_000e18);
        uint256 reserve0 = vault.rewardReserve();

        _rawSell(alice, token.balanceOf(alice), TickMath.getSqrtPriceAtTick(highest + hook.TICK_SPACING()));
        for (uint256 i; i < 150; i++) {
            (, uint128 liquidity,,) = hook.walls(ids[i]);
            assertEq(liquidity, 0, "a crossed wall was left in place");
        }
        _assertNoCrossedWall();
        uint256 absorbed = hook.pendingAbsorbedTokens();
        assertGt(absorbed, 0);
        _assertBooks();

        hook.deliverAbsorbed();
        assertEq(vault.rewardReserve() - reserve0, absorbed, "absorbed CUBIT did not reach the reserve");
        assertEq(hook.pendingAbsorbedTokens(), 0);
        _assertBooks();
    }

    /// Under the launch price the 40/60 target is at or above the market: the sale's 12% goes 1% under the price instead
    /// of waiting, so no pile of wall funds builds up for a later sale to place at a price its seller pushed up.
    function testFuzz_underLaunchTheWallGoesOnePercentUnderTheMarket(uint256 ethIn, uint256 extra, uint256 past)
        public
    {
        ethIn = bound(ethIn, 0.05 ether, 5 ether);
        extra = bound(extra, 100_000e18, 3_000_000e18);
        uint256 bought = _buy(alice, ethIn);
        _giveReserveCubit(alice, extra);
        (, int24 upper,) = hook.band();
        int24 limit = upper + int24(int256(bound(past, 200, 60_000)));
        _rawSell(alice, bought + extra, TickMath.getSqrtPriceAtTick(limit));
        int24 spacing = hook.TICK_SPACING();
        int24 tick = _tick();
        uint160 sqrtP = _sqrtP();
        assertGt(tick, upper, "the sale did not push the price under the band's top");
        assertGe(tick, BandLib.retracementWallTarget(hook.INITIAL_SQRT_PRICE(), sqrtP, spacing), "40/60 was under the market");
        assertLe(hook.pendingFloorEth(), 1, "the 12% waited");
        (int24 lower, uint128 liquidity,,) = hook.walls(hook.latestWallId());
        uint256 mark = BandLib.ethPerCubitAtSqrt(sqrtP) * 9_900 / 10_000;
        assertGt(liquidity, 0);
        assertGt(lower, tick, "the wall is not strictly under the market");
        assertEq(lower, BandLib.underMarketWallTarget(sqrtP, spacing));
        assertLe(BandLib.ethPerCubitAtTick(lower), mark, "the wall is less than 1% under the price");
        assertGe(
            BandLib.ethPerCubitAtTick(lower - spacing) * 1_000_001 / 1_000_000,
            mark,
            "the wall sits more than one spacing under the 1% mark"
        );
        _assertBooks();
    }

    /// At the top of the tick range no position fits under the price: only that sale's own 12% waits, and the next sale
    /// with room places it. Only the seller who pushed the price there can leave funds waiting.
    function test_atTheTopOfTheTickRangeOnlyThatSalesTwelvePercentWaits() public {
        uint256 bought = _buy(alice, 1 ether);
        _giveReserveCubit(alice, 1_000_000e18);
        _rawSell(alice, bought + 1_000_000e18, TickMath.MAX_SQRT_PRICE - 1);
        assertGt(hook.pendingFloorEth(), 0, "the sale's 12% did not wait at the top of the range");
        assertEq(hook.activeWallCount(), 0, "a wall was placed without room under the price");
        uint256 got = _buy(bob, 1 ether);
        _sell(bob, got / 10);
        assertLe(hook.pendingFloorEth(), 1, "the next sale did not place what waited");
        _assertBooks();
    }
}
