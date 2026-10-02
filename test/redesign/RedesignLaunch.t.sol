// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LensReads} from "../utils/LensReads.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";

/// @notice The launch transaction: 80% in the band, 20% in the vault reserve, an optional dev buy taxed like any buy,
///         and a deployer left with nothing but what that buy bought. The Lens does not count the reserve.
contract RedesignLaunchTest is RedesignBase {
    function _launchInSetUp() internal pure override returns (bool) {
        return false;
    }

    function testFuzz_launchSplitsTheSupply(uint256 devBuy) public {
        devBuy = bound(devBuy, 0, 5 ether);
        if (devBuy != 0 && devBuy < 1e6) devBuy = 1e6;
        uint256 bought = _launch(devBuy);

        assertTrue(hook.initialized());
        assertEq(vault.rewardReserve(), RESERVE, "the reserve does not hold 20%");
        assertEq(token.balanceOf(address(vault)), RESERVE);
        assertEq(token.balanceOf(address(launcher)), 0, "the launcher kept CUBIT");
        assertEq(token.balanceOf(address(this)), bought, "the deployer kept CUBIT beyond the dev buy");
        assertEq(hook.teamAccrued(), FullMath.mulDivRoundingUp(devBuy, 300, 10_000), "the dev buy is not taxed 3%");
        assertEq(hook.activeWallCount(), 0, "a buy placed a wall");
        assertEq(hook.pendingFloorEth(), 0);

        uint256 burned = token.totalBurned();
        assertLt(burned, 10_000, "the bootstrap burned more than rounding dust");
        (,, uint128 liquidity) = hook.band();
        assertGt(liquidity, 0);
        assertEq(lens.rewardReserve(), RESERVE);
        assertEq(LensReads.circulatingSupply(lens), token.totalSupply() - RESERVE, "the Lens counts the reserve");
        assertApproxEqAbs(LensReads.heldSupply(lens), bought, 10, "holders hold more than the dev buy at launch");
        _assertBooks();
    }

    function test_decidedDevBuy() public {
        assertEq(_launch(0.1 ether), 526108113121399541651328, "0.1 ETH no longer buys 526,108.11 CUBIT");
        assertEq(hook.teamAccrued(), 0.003 ether);
    }

    function test_launchIsOneShotAndDeployerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("launch unavailable"));
        launcher.launch(0);
        _launch(0);
        vm.expectRevert(bytes("launch unavailable"));
        launcher.launch(0);
    }
}
