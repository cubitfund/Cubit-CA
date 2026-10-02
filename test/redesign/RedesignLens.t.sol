// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LensReads} from "../utils/LensReads.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";
import {ICubitLens} from "../../src/interfaces/ICubitLens.sol";

/// @dev A vault the team could register by mistake: its getters pass the registry, but its reserve read reverts or
///      claims far more than it holds.
contract BrokenReserveVault {
    address public immutable hook;
    address public immutable token;
    bool public immutable reverts;
    uint256 public totalStaked;

    constructor(address hook_, address token_, bool reverts_) {
        hook = hook_;
        token = token_;
        reverts = reverts_;
    }

    function rewardReserve() external view returns (uint256) {
        if (reverts) revert("reserve read broken");
        return type(uint256).max / 2;
    }

    function fundRewardReserve(uint256) external pure {
        revert("no funding");
    }
}

/// @notice The figures the dashboard shows: what holders hold, apart from the band's unsold stock; the
///         active wall nearest to the market, rather than the latest funded one, which a sale may have emptied; and reads
///         no registered vault can break.
contract RedesignLensTest is RedesignBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// At launch holders hold nothing: the band's unsold CUBIT and the vault reserve are not held. After trades, the held
    /// supply is what the traders keep.
    function test_heldSupplyLeavesTheBandOut() public {
        assertEq(LensReads.circulatingSupply(lens), token.totalSupply() - RESERVE, "circulating at launch");
        assertLe(LensReads.heldSupply(lens), 10, "holders hold the band's stock at launch");
        uint256 bought = _buy(alice, 1 ether);
        assertApproxEqAbs(LensReads.heldSupply(lens), bought, 10, "the held supply is not what was bought");
        uint256 sold = bought / 2;
        _sell(alice, sold);
        // The pool fee on a sale is paid in CUBIT and stays inside the positions, uncollected: it counts as held.
        assertApproxEqAbs(LensReads.heldSupply(lens), token.balanceOf(alice), sold / 5_000 + 10, "the held supply after a sale");
        ICubitLens.Snapshot memory s = lens.snapshot();
        assertEq(s.totalSupply, token.totalSupply());
        assertEq(s.pendingAbsorbedTokens, hook.pendingAbsorbedTokens());
        assertEq(s.activeWallCount, hook.activeWallCount());
    }

    /// The best wall is the lowest active tick. A sale to the top of the tick range empties every wall and has no room
    /// to place one: the latest funded wall is then empty but still priced, while the best wall is gone.
    function test_bestWallIsTheNearestStandingWall() public {
        assertEq(lens.bestWallPrice(), 0, "a best wall before any sale");
        uint256 got = _buy(alice, 1 ether);
        _sell(alice, got / 10);
        got = _buy(bob, 3 ether);
        _sell(bob, got / 10);
        uint256 live = hook.activeWallCount();
        assertGe(live, 2, "the fixture needs two walls");
        int24 lowest = type(int24).max;
        for (uint256 i; i < live; i++) {
            (int24 lower,,,) = hook.walls(hook.activeWallId(i));
            if (lower < lowest) lowest = lower;
        }
        (bool exists, int24 nearest) = hook.nearestWallTick();
        assertTrue(exists);
        assertEq(nearest, lowest, "the nearest wall is not the lowest active tick");
        assertEq(lens.bestWallPrice(), BandLib.ethPerCubitAtTick(nearest));
        assertLt(lens.netBestWallPrice(), lens.bestWallPrice());
        assertEq(lens.snapshot().bestWallPrice, lens.bestWallPrice());

        // Every CUBIT bought, plus the whole reserve, sold at once: enough to cross both walls and the band.
        uint256 bobHeld = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(alice, bobHeld);
        _giveReserveCubit(alice, RESERVE);
        _rawSell(alice, token.balanceOf(alice), TickMath.MAX_SQRT_PRICE - 1);
        assertEq(hook.activeWallCount(), 0, "a wall still stands");
        assertEq(hook.wallLiquidity(), 0, "the latest funded wall still holds liquidity");
        assertGt(lens.floorPrice(), 0, "the latest-wall price vanished");
        (exists,) = hook.nearestWallTick();
        assertFalse(exists);
        assertEq(lens.bestWallPrice(), 0, "a best wall with no wall standing");
        assertEq(lens.netBestWallPrice(), 0);
        assertEq(lens.snapshot().bestWallPrice, 0);
    }

    /// A registered vault whose reserve read reverts counts for nothing; one that over-reports counts at most the CUBIT
    /// it holds. Neither breaks the figures.
    function test_brokenVaultCannotBreakTheFigures() public {
        BrokenReserveVault reverting = new BrokenReserveVault(address(hook), address(token), true);
        BrokenReserveVault lying = new BrokenReserveVault(address(hook), address(token), false);
        vm.startPrank(team);
        registry.setVault(address(reverting));
        registry.setVault(address(lying));
        vm.stopPrank();
        assertEq(registry.vaultCount(), 3);
        assertEq(lens.rewardReserve(), RESERVE, "a broken vault changed the reserve");
        ICubitLens.Snapshot memory s = lens.snapshot();
        assertEq(s.rewardReserve, RESERVE);
        assertEq(LensReads.circulatingSupply(lens), s.totalSupply - RESERVE);

        uint256 got = _buy(alice, 0.1 ether);
        vm.prank(alice);
        token.transfer(address(lying), got);
        assertEq(lens.rewardReserve(), RESERVE + got, "an over-report counted beyond the vault's holding");
        assertEq(lens.snapshot().rewardReserve, RESERVE + got);
    }
}
