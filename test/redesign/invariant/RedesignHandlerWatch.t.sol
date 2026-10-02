// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {CubitToken} from "../../../src/CubitToken.sol";
import {CubitHook} from "../../../src/CubitHook.sol";
import {CubitLens} from "../../../src/CubitLens.sol";
import {CubitRouter} from "../../../src/periphery/CubitRouter.sol";
import {CubitV2} from "../../../src/periphery/CubitV2.sol";
import {BandLib} from "../../../src/libraries/BandLib.sol";
import {RedesignBase} from "../utils/RedesignBase.sol";
import {RedesignHandler} from "./RedesignHandler.sol";

/// @dev Direct regression tests of BandLib's rounding boundary and the hook's per-position capacity.
contract RedesignHandlerWatchTest is Test {
    function test_pendingWatchBoundaryUsesRoundedPrice() public pure {
        int24[6] memory ticks = [int24(400_000), 403_500, 407_553, 407_554, 407_555, 414_487];
        uint256[6] memory expected = [uint256(4), 2, 2, 2, 1, 0];
        for (uint256 i; i < ticks.length; i++) {
            uint160 sqrtP = TickMath.getSqrtPriceAtTick(ticks[i]);
            uint256 price = BandLib.ethPerCubitAtSqrt(sqrtP);
            int24 target = BandLib.underMarketWallTarget(sqrtP, 10);
            assertEq(price, expected[i]);
            console2.log("REVIEW_BOUNDARY tick", int256(ticks[i]));
            console2.log("price", price);
            console2.log("target", int256(target));
            if (price >= 2) assertLt(target, TickMath.maxUsableTick(10) - 10);
            else assertEq(target, TickMath.maxUsableTick(10) - 10);
        }
        uint160 top = TickMath.getSqrtPriceAtTick(407_555) - 1;
        assertEq(TickMath.getTickAtSqrtPrice(top), 407_554);
        assertEq(BandLib.ethPerCubitAtSqrt(top), 1);
        assertEq(BandLib.underMarketWallTarget(top, 10), 887_260);
        // Exact adjacent sqrt prices after BOTH integer divisions in ethPerCubitAtSqrt.
        uint160 firstCollapsed = 56_022_770_960_006_322_338_868_149_104_112_828_417;
        assertEq(TickMath.getTickAtSqrtPrice(firstCollapsed - 1), 407_554);
        assertEq(TickMath.getTickAtSqrtPrice(firstCollapsed), 407_554);
        assertEq(BandLib.ethPerCubitAtSqrt(firstCollapsed - 1), 2);
        assertEq(BandLib.ethPerCubitAtSqrt(firstCollapsed), 1);
        assertEq(BandLib.underMarketWallTarget(firstCollapsed - 1, 10), 414_490);
        assertEq(BandLib.underMarketWallTarget(firstCollapsed, 10), 887_260);
    }

    function test_extendedWatchHasNoUncappedDust() public pure {
        uint128 cap = BandLib.maxLiquidityPerTick(10) / 4;
        uint256[5] memory budgets = [uint256(1), 1e9, 1 ether, 25 ether, 30_000 ether];
        uint256 maxDust;
        uint256 minCapacity = type(uint256).max;
        for (int24 tick = 400_000; tick <= 407_554; tick++) {
            int24 target = BandLib.underMarketWallTarget(TickMath.getSqrtPriceAtTick(tick), 10);
            uint160 a = TickMath.getSqrtPriceAtTick(target);
            uint160 b = TickMath.getSqrtPriceAtTick(target + 10);
            uint256 width = uint256(b) - a;
            uint256 intermediate = FullMath.mulDiv(a, b, 1 << 96);
            uint256 maxUncappedBudget = FullMath.mulDivRoundingUp(cap, width, intermediate) - 1;
            // Bound both floor errors below one wei for EVERY uncapped integer budget at this target.
            assertLt((maxUncappedBudget + width) * (1 << 96), uint256(a) * b);
            for (uint256 i; i < budgets.length; i++) {
                (uint128 liq, uint256 used) = BandLib.liquidityForEth(a, b, budgets[i], cap);
                if (liq < cap) {
                    uint256 dust = budgets[i] - used;
                    if (dust > maxDust) maxDust = dust;
                    assertEq(dust, 0);
                } else if (used < minCapacity) minCapacity = used;
            }
        }
        console2.log("REVIEW_DUST maxUnsaturatedDust", maxDust);
        console2.log("REVIEW_DUST minCapacity", minCapacity);
    }

    function testFuzz_partialWallLeavesFundsOnlyAtCapacity(int24 tick, uint256 budget, uint128 existing) public pure {
        tick = int24(_bound(int256(tick), 400_000, 407_554));
        budget = _bound(budget, 1, 30_000 ether);
        uint128 cap = BandLib.maxLiquidityPerTick(10) / 4;
        existing = uint128(_bound(uint256(existing), 0, cap));
        int24 target = BandLib.underMarketWallTarget(TickMath.getSqrtPriceAtTick(tick), 10);
        (uint128 added, uint256 used) = BandLib.liquidityForEth(
            TickMath.getSqrtPriceAtTick(target), TickMath.getSqrtPriceAtTick(target + 10), budget, cap - existing
        );
        assertLe(used, budget);
        if (existing + added < cap) assertEq(used, budget);
    }
}

/// @dev Expose the real handler checks to directed fixtures without adding a fuzz action.
contract RedesignHandlerProbe is RedesignHandler {
    constructor(
        IPoolManager manager_,
        CubitToken token_,
        CubitHook hook_,
        CubitLens lens_,
        CubitRouter router_,
        CubitV2 registry_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        address team_
    ) RedesignHandler(manager_, token_, hook_, lens_, router_, registry_, swapRouter_, lpRouter_, team_) {}

    function checkSale() external {
        _assertNoWallFundsPile();
        _afterStep();
    }
}

contract RedesignHandlerPlacementTest is RedesignBase {
    RedesignHandlerProbe internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(START + 3 days);
        vm.prank(team);
        registry.activate(1);
        handler = new RedesignHandlerProbe(
            manager, token, hook, lens, router, registry, swapRouter, new PoolModifyLiquidityTest(manager), team
        );
    }

    function _buyFromActor(address who, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return router.swapExactIn{value: eth}(key, true, eth, 0, who, type(uint256).max);
    }

    function _rewardedSeller(uint256 eth) internal returns (address who, uint256 available) {
        who = handler.actors(0);
        uint256 bought = _buyFromActor(who, eth);
        vm.startPrank(who);
        token.approve(address(vault), bought);
        vault.stake(bought);
        vm.stopPrank();
        vm.warp(block.timestamp + vault.REWARD_PERIOD());
        vm.prank(who);
        vault.withdraw(bought);
        available = token.balanceOf(who);
        assertGt(available, bought);
    }

    function test_directedSalesDistinguishDustCapacityAndSkippedRange() public {
        int24[5] memory ticks = [int24(399_999), 400_000, 407_553, 407_554, 407_555];
        uint256[2] memory budgets = [uint256(1 ether), 5_000 ether];
        for (uint256 b; b < budgets.length; b++) {
            for (uint256 i; i < ticks.length; i++) {
                uint256 snap = vm.snapshotState();
                (address seller, uint256 available) = _rewardedSeller(budgets[b]);
                _rawSell(seller, available, TickMath.getSqrtPriceAtTick(ticks[i]));
                assertEq(_tick(), ticks[i]);
                _assertBooks();
                uint256 pending = hook.pendingFloorEth();
                if (b == 0 && ticks[i] <= 407_554) assertEq(pending, 0);
                else assertGt(pending, 1e9);
                (int24 lower, uint128 liq,,) = hook.walls(hook.latestWallId());
                handler.checkSale();
                handler.checkAll();
                assertEq(handler.maxTick(), ticks[i]);
                assertEq(handler.maxPendingAfterSale(), pending);
                assertEq(handler.salesInExtendedWatch(), ticks[i] >= 400_000 && ticks[i] <= 407_554 ? 1 : 0);
                assertEq(handler.salesOutsidePendingWatch(), ticks[i] > 407_554 ? 1 : 0);
                assertEq(handler.salesAtWallCapacity(), b == 1 && ticks[i] <= 407_554 ? 1 : 0);
                console2.log(string.concat(
                    "REVIEW_DIRECTED buy=", vm.toString(budgets[b]),
                    " tick=", vm.toString(int256(_tick())),
                    " target=", vm.toString(int256(lower)),
                    " pending=", vm.toString(pending),
                    " saturated=", vm.toString(liq == hook.MAX_LIQUIDITY_PER_TICK())
                ));
                vm.revertToState(snap);
            }
        }
    }

    function test_extendedWatchRejectsEvenOneWeiWithoutCapacityPressure() public {
        (address seller, uint256 available) = _rewardedSeller(1 ether);
        _rawSell(seller, available, TickMath.getSqrtPriceAtTick(407_554));
        assertEq(hook.pendingFloorEth(), 0);
        vm.mockCall(address(hook), abi.encodeWithSignature("pendingFloorEth()"), abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 1));
        handler.checkSale();
        vm.clearMockedCalls();
    }

    function test_bothSidesOfCliffInsideTheSameTick() public {
        uint160 firstCollapsed = 56_022_770_960_006_322_338_868_149_104_112_828_417;
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            (address seller, uint256 available) = _rewardedSeller(1 ether);
            _rawSell(seller, available, firstCollapsed - 1 + uint160(i));
            assertEq(_tick(), 407_554);
            if (i == 0) assertEq(hook.pendingFloorEth(), 0);
            else assertGt(hook.pendingFloorEth(), 1e9);
            handler.checkSale();
            handler.checkAll();
            assertEq(handler.salesInExtendedWatch(), 1 - i);
            assertEq(handler.salesOutsidePendingWatch(), i);
            assertEq(handler.maxPendingAfterSale(), hook.pendingFloorEth());
            vm.revertToState(snap);
        }
    }

    function test_globalPendingWitnessSurvivesReturnToWatchedPrices() public {
        (address seller, uint256 available) = _rewardedSeller(1 ether);
        _rawSell(seller, available, TickMath.getSqrtPriceAtTick(407_555));
        uint256 skippedPending = hook.pendingFloorEth();
        assertGt(skippedPending, 1e9);
        handler.checkSale();
        handler.checkAll();
        assertEq(handler.maxPendingAfterSale(), skippedPending);

        address buyer = handler.actors(1);
        uint256 fresh = _buyFromActor(buyer, 1 ether);
        _sell(buyer, fresh / 10);
        assertLt(_tick(), 400_000);
        assertEq(hook.pendingFloorEth(), 0);
        handler.checkSale();
        handler.checkAll();
        assertEq(handler.maxPendingAfterSale(), skippedPending);
        assertEq(handler.salesOutsidePendingWatch(), 1);
    }
}
