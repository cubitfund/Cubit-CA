// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";

/// @notice Taxes in the four modes: 3% of a buy to the team, 15% of a sale split 12% walls / 3% team, always on the
///         ETH leg, and no trade ever filled at a better rate than the pre-trade spot price.
contract RedesignTaxesTest is RedesignBase {
    address internal alice = makeAddr("alice");

    function testFuzz_buyExactIn(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e9, 40 ether);
        uint256 pending0 = hook.pendingFloorEth();
        uint160 sqrtBefore = _sqrtP();
        uint256 out = _buy(alice, ethIn);
        assertEq(hook.teamAccrued(), FullMath.mulDivRoundingUp(ethIn, 300, 10_000), "buy tax is not 3%");
        assertEq(hook.pendingFloorEth(), pending0, "a buy funded walls");
        assertEq(token.balanceOf(alice), out);
        assertLe(out, _cubitAt(ethIn, sqrtBefore), "a buy was filled above the spot");
        _assertBooks();
    }

    function testFuzz_buyExactOut(uint256 cubitOut) public {
        cubitOut = bound(cubitOut, 1e12, 8_000_000e18);
        uint160 sqrtBefore = _sqrtP();
        uint256 gross = _buyExactOut(alice, cubitOut, 100 ether);
        uint256 tax = hook.teamAccrued();
        assertEq(tax, FullMath.mulDivRoundingUp(gross - tax, 300, 9_700), "exact-output buy tax is not 3%");
        assertEq(token.balanceOf(alice), cubitOut, "exact output not delivered");
        assertLe(cubitOut, _cubitAt(gross, sqrtBefore), "a buy was filled above the spot");
        _assertBooks();
    }

    function testFuzz_sellExactIn(uint256 ethIn, uint256 bps) public {
        ethIn = bound(ethIn, 0.001 ether, 30 ether);
        uint256 bought = _buy(alice, ethIn);
        uint256 amount = bought * bound(bps, 1, 10_000) / 10_000;
        vm.assume(amount != 0);
        uint256 team0 = hook.teamAccrued();
        uint256 floor0 = _floorEth();
        uint160 sqrtBefore = _sqrtP();
        uint256 net = _sell(alice, amount);
        _assertSellSplit(net, hook.teamAccrued() - team0, _floorEth() - floor0);
        assertLe(_cubitAt(net, sqrtBefore), amount, "a sale was filled above the spot");
        _assertBooks();
        _assertNoCrossedWall();
    }

    function testFuzz_sellExactOut(uint256 ethIn, uint256 bps) public {
        ethIn = bound(ethIn, 0.01 ether, 30 ether);
        uint256 bought = _buy(alice, ethIn);
        uint256 net = ethIn * bound(bps, 1, 5_000) / 10_000;
        uint256 team0 = hook.teamAccrued();
        uint160 sqrtBefore = _sqrtP();
        uint256 used = _sellExactOut(alice, net, bought);
        uint256 tax = FullMath.mulDivRoundingUp(net, 1_500, 8_500);
        assertEq(hook.teamAccrued() - team0, tax * 300 / 1_500, "exact-output sale team share is not 3%");
        assertEq(token.balanceOf(alice), bought - used);
        assertLe(_cubitAt(net, sqrtBefore), used, "a sale was filled above the spot");
        _assertBooks();
        _assertNoCrossedWall();
    }

    /// Buying then selling the same CUBIT right away always returns less ETH than it cost.
    function testFuzz_roundTripNeverProfits(uint256 ethIn, uint256 seed) public {
        ethIn = bound(ethIn, 1e12, 30 ether);
        // random history first: walls at various prices
        for (uint256 i; i < 6; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 got = _buy(alice, 0.01 ether + r % 2 ether);
            _sell(alice, got * (1 + r % 5_000) / 10_000);
        }
        address bob = makeAddr("bob");
        uint256 out = _buy(bob, ethIn);
        uint256 back = _sell(bob, out);
        assertLt(back, ethIn, "a round trip returned more ETH than it cost");
        _assertBooks();
        _assertNoCrossedWall();
    }
}
