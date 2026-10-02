// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LensReads} from "../utils/LensReads.sol";

import {RedesignBase} from "./utils/RedesignBase.sol";
import {CubitVault} from "../../src/periphery/CubitVault.sol";

/// @notice The CUBIT-only vault: 3% of the stake per 24 hours, capped at one period, paid out of the reserve the launch
///         seeded, a 24-hour lock, principal never touched, and a Lens that counts paid rewards as circulating.
contract RedesignVaultTest is RedesignBase {
    address internal alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        vm.warp(START + 3 days);
        vm.prank(team);
        registry.activate(1);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function testFuzz_dailyRewardFromTheReserve(uint256 ethIn, uint256 elapsed) public {
        ethIn = bound(ethIn, 0.001 ether, 20 ether);
        elapsed = bound(elapsed, 0, 5 days);
        uint256 stake = _buy(alice, ethIn);
        _stake(alice, stake);
        uint256 circulating0 = LensReads.circulatingSupply(lens);

        vm.warp(START + 3 days + elapsed);
        uint256 capped = elapsed > 1 days ? 1 days : elapsed;
        uint256 expected = stake * 300 * capped / (10_000 * 1 days);
        assertEq(vault.pendingCubit(alice), expected, "reward is not 3% per day capped at one day");

        vm.prank(alice);
        vault.claimCubit();
        assertEq(token.balanceOf(alice), expected);
        assertEq(vault.rewardReserve(), RESERVE - expected, "reward not paid from the reserve");
        assertEq(vault.totalCubitPaid(), expected);
        assertEq(vault.totalStaked(), stake, "claiming touched the principal");
        assertEq(LensReads.circulatingSupply(lens), circulating0 + expected, "a paid reward is not circulating");
    }

    function testFuzz_withdrawWaitsForTheLock(uint256 ethIn, uint256 wait) public {
        ethIn = bound(ethIn, 0.001 ether, 10 ether);
        wait = bound(wait, 0, 2 days);
        uint256 stake = _buy(alice, ethIn);
        _stake(alice, stake);
        vm.warp(START + 3 days + wait);
        vm.prank(alice);
        if (wait < 1 days) {
            vm.expectRevert(CubitVault.Locked.selector);
            vault.withdraw(stake);
            return;
        }
        vault.withdraw(stake);
        uint256 reward = stake * 300 / 10_000; // a full period elapsed
        assertEq(token.balanceOf(alice), stake + reward, "withdraw did not return principal plus the settled reward");
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_rewardsStopWhenTheReserveIsSpent() public {
        uint256 stake = _buy(alice, 30 ether);
        _stake(alice, stake);
        uint256 paid;
        for (uint256 day = 1; day <= 40; day++) {
            vm.warp(START + 3 days + day * 1 days);
            uint256 due = vault.pendingCubit(alice);
            vm.prank(alice);
            vault.claimCubit();
            paid += due;
            if (vault.rewardReserve() == 0) break;
        }
        assertEq(vault.rewardReserve(), 0, "40 days of 3% did not spend the reserve");
        assertEq(paid, RESERVE, "rewards paid more or less than the reserve");
        assertEq(vault.pendingCubit(alice), 0, "a reward is due with an empty reserve");
        vm.prank(alice);
        vault.withdraw(stake);
        assertEq(token.balanceOf(alice), stake + RESERVE, "principal was touched");
    }
}
