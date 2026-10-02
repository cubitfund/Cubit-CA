// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {assertInvariant} from "../../utils/InvariantAssertions.sol";
import {RedesignBase} from "../utils/RedesignBase.sol";
import {RedesignHandler} from "./RedesignHandler.sol";

/// @notice The redesigned release under random sequences of trades, deliveries, vault use, vault replacement, time and
///         outsiders. Each invariant function is its own campaign, so Foundry runs them in parallel; every one of them
///         also runs the handler's per-action checks (prices, round trips, payouts, monotone books).
///         Large runs: FOUNDRY_INVARIANT_RUNS=<runs> FOUNDRY_INVARIANT_DEPTH=<depth> forge test --mc RedesignInvariants
contract RedesignInvariants is RedesignBase {
    RedesignHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(START + 3 days);
        vm.prank(team);
        registry.activate(1);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        handler = new RedesignHandler(manager, token, hook, lens, router, registry, swapRouter, lpRouter, team);
        targetContract(address(handler));

        bytes4[] memory s = new bytes4[](26);
        s[0] = RedesignHandler.buyExactIn.selector;
        s[1] = RedesignHandler.buyExactIn.selector;
        s[2] = RedesignHandler.buyExactIn.selector;
        s[3] = RedesignHandler.buyExactOut.selector;
        s[4] = RedesignHandler.sellExactIn.selector;
        s[5] = RedesignHandler.sellExactIn.selector;
        s[6] = RedesignHandler.sellExactIn.selector;
        s[7] = RedesignHandler.sellExactOut.selector;
        s[8] = RedesignHandler.rawSell.selector;
        s[9] = RedesignHandler.rawSell.selector;
        s[10] = RedesignHandler.rawBuy.selector;
        s[11] = RedesignHandler.roundTrip.selector;
        s[12] = RedesignHandler.deliverAbsorbed.selector;
        s[13] = RedesignHandler.claimTeam.selector;
        s[14] = RedesignHandler.stake.selector;
        s[15] = RedesignHandler.stake.selector;
        s[16] = RedesignHandler.withdraw.selector;
        s[17] = RedesignHandler.claimCubit.selector;
        s[18] = RedesignHandler.claimCubit.selector;
        s[19] = RedesignHandler.fundReserve.selector;
        s[20] = RedesignHandler.donateToVault.selector;
        s[21] = RedesignHandler.replaceVault.selector;
        s[22] = RedesignHandler.warp.selector;
        s[23] = RedesignHandler.warp.selector;
        s[24] = RedesignHandler.externalLiquidity.selector;
        s[25] = RedesignHandler.buyExactIn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    /// Hook books reconcile with its PoolManager claims to the wei; supply is fixed and nothing burns after launch.
    function invariant_booksAndSupply() public view {
        handler.checkBooksAndSupply();
    }

    /// No ETH is created or destroyed; the team only ever receives what claimTeam pays.
    function invariant_ethConservation() public view {
        handler.checkEth();
    }

    /// Walls match the PoolManager, never stay fully crossed, and the band never changes.
    function invariant_wallsAndBand() public view {
        handler.checkWallsAndBand();
    }

    /// Every vault is solvent and the Lens reports reserves and circulating supply exactly.
    function invariant_vaultsAndLens() public view {
        handler.checkVaultsAndLens();
    }

    /// A long run that executed no trade proves nothing.
    function afterInvariant() public view {
        if (handler.calls() >= 64) {
            assertInvariant(handler.buys() + handler.sells() + handler.rawTrades() > 0, "a long run executed no trade");
        }
    }
}
