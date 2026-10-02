// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {assertInvariant} from "../../test/utils/InvariantAssertions.sol";
import {RedesignInvariants} from "../../test/redesign/invariant/RedesignInvariants.t.sol";

/// @notice Medusa entry point for the redesigned release: the handler and the four invariants of the Foundry campaign
///         (test/redesign/invariant), fuzzed by a second engine with its own corpus and coverage guidance.
///
/// @dev    Medusa fuzzes the target contract's own methods and ignores Foundry's targetContract/targetSelector, so
///         this harness runs the setup in its constructor and re-exposes the handler's actions; medusa-redesign.json
///         whitelists exactly those and the invariant_* checks. setUp() stays out of the whitelist: a random call must
///         not reset a sequence. Checks fail with Panic(0x01) (test/utils/InvariantAssertions.sol), which Medusa's
///         assertion mode reports wherever it happens in the call, including inside the handler.
///
///         Lives under audit/ so `forge test` does not run the invariant suite twice. From the repository root:
///           FOUNDRY_TEST=audit/medusa-redesign medusa fuzz --config medusa-redesign.json
contract RedesignMedusa is RedesignInvariants {
    constructor() {
        setUp();
        // Medusa checks a call's value against the calling contract's balance before the prank applies: without this,
        // every ETH buy fails before reaching the router. The ETH universe is read again to include it.
        vm.deal(address(handler), 1_000_000 ether);
        handler.syncEthUniverse();
    }

    // ------------------------------------------------------------------ trades
    function medusaBuyExactIn(uint256 seed, uint256 eth) public {
        handler.buyExactIn(seed, eth);
    }

    function medusaBuyExactOut(uint256 seed, uint256 cubit) public {
        handler.buyExactOut(seed, cubit);
    }

    function medusaSellExactIn(uint256 seed, uint256 bps) public {
        handler.sellExactIn(seed, bps);
    }

    function medusaSellExactOut(uint256 seed, uint256 bps) public {
        handler.sellExactOut(seed, bps);
    }

    function medusaRoundTrip(uint256 seed, uint256 eth) public {
        handler.roundTrip(seed, eth);
    }

    function medusaRawSell(uint256 seed, uint256 bps, uint256 ticks) public {
        handler.rawSell(seed, bps, ticks);
    }

    function medusaRawBuy(uint256 seed, uint256 eth) public {
        handler.rawBuy(seed, eth);
    }

    // ------------------------------------------------------------------ public functions of the hook
    function medusaDeliverAbsorbed(uint256 seed) public {
        handler.deliverAbsorbed(seed);
    }

    function medusaClaimTeam(uint256 seed) public {
        handler.claimTeam(seed);
    }

    // ------------------------------------------------------------------ vault and registry
    function medusaStake(uint256 seed, uint256 bps) public {
        handler.stake(seed, bps);
    }

    function medusaWithdraw(uint256 seed, uint256 vaultSeed, uint256 bps) public {
        handler.withdraw(seed, vaultSeed, bps);
    }

    function medusaClaimCubit(uint256 seed, uint256 vaultSeed) public {
        handler.claimCubit(seed, vaultSeed);
    }

    function medusaFundReserve(uint256 seed, uint256 bps) public {
        handler.fundReserve(seed, bps);
    }

    function medusaDonateToVault(uint256 seed, uint256 bps) public {
        handler.donateToVault(seed, bps);
    }

    function medusaReplaceVault() public {
        handler.replaceVault();
    }

    // ------------------------------------------------------------------ time and outsiders
    function medusaWarp(uint256 secs) public {
        handler.warp(secs);
    }

    function medusaExternalLiquidity(uint256 seed, int256 offset) public {
        handler.externalLiquidity(seed, offset);
    }
}

/// @notice Negative control: the same campaign with one property that must break as soon as a sale succeeds. A run
///         that does not report it FAILED proves nothing about the real properties.
contract RedesignMedusaNegativeControl is RedesignMedusa {
    function invariant_negativeControl_noSaleEverSucceeds() public view {
        assertInvariant(handler.sells() == 0, "negative control: a sale succeeded");
    }
}
