// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {assertInvariant} from "../../test/utils/InvariantAssertions.sol";
import {QuoteInvariants} from "../../test/redesign/invariant/QuoteInvariants.t.sol";
import {MockQuote, MockNoReturnQuote} from "../../script/mocks/TestQuotes.sol";

/// @notice Medusa entry point for the launchpad v2: QuoteHandler and its invariant checks, fuzzed by a second engine with
///         its own corpus and coverage guidance. Same pattern as audit/medusa-redesign: the constructor runs setUp (four
///         children on one PoolManager: ETH, two USDC, WBTC), the methods re-expose the handler's actions, and
///         medusa-quote.json whitelists exactly those and the invariant check. Checks fail with Panic(0x01).
///         From the repository root:
///           FOUNDRY_TEST=audit/medusa-quote forge build --build-info audit/medusa-quote/QuoteMedusa.sol
///           (delete build-info files without an `output` key), then
///           FOUNDRY_TEST=audit/medusa-quote medusa fuzz --config medusa-quote.json
contract QuoteMedusa is QuoteInvariants {
    constructor() {
        // Medusa checks a call's value against the calling contract's balance before the prank applies: the launches
        // in setUp send their fee from this contract's point of view, and the handler's ETH trades from the handler's.
        vm.deal(address(this), 1_000_000 ether);
        setUp();
        vm.deal(address(handler), 1_000_000 ether);
    }

    /// @dev Test quotes at ordinary addresses: Medusa does not execute code placed with vm.etch.
    function _setUpQuotes() internal override {
        USDC = address(new MockQuote("USDC", 6));
        USDT = address(new MockNoReturnQuote());
        WBTC = address(new MockQuote("WBTC", 8));
        TSLAON = address(new MockQuote("TSLAon", 18));
    }

    function medusaBuyExactIn(uint256 hookSeed, uint256 actorSeed, uint256 amount) public {
        handler.buyExactIn(hookSeed, actorSeed, amount);
    }

    function medusaBuyExactOut(uint256 hookSeed, uint256 actorSeed, uint256 tokens) public {
        handler.buyExactOut(hookSeed, actorSeed, tokens);
    }

    function medusaSellExactIn(uint256 hookSeed, uint256 actorSeed, uint256 bps) public {
        handler.sellExactIn(hookSeed, actorSeed, bps);
    }

    function medusaSellExactOut(uint256 hookSeed, uint256 actorSeed, uint256 quoteOut) public {
        handler.sellExactOut(hookSeed, actorSeed, quoteOut);
    }

    function medusaRawSell(uint256 hookSeed, uint256 actorSeed, uint256 bps, uint256 ticks) public {
        handler.rawSell(hookSeed, actorSeed, bps, ticks);
    }

    function medusaTwoHop(uint256 aSeed, uint256 bSeed, uint256 actorSeed, uint256 bps) public {
        handler.twoHop(aSeed, bSeed, actorSeed, bps);
    }

    function medusaDeliverAbsorbed(uint256 hookSeed) public {
        handler.deliverAbsorbed(hookSeed);
    }

    function medusaClaimTeam(uint256 hookSeed) public {
        handler.claimTeam(hookSeed);
    }

    function medusaDonateClaims(uint256 hookSeed, uint256 amount) public {
        handler.donateClaims(hookSeed, amount);
    }

    function medusaDonateRaw(uint256 hookSeed, uint256 actorSeed, uint256 amount, bool tokens) public {
        handler.donateRaw(hookSeed, actorSeed, amount, tokens);
    }

    function invariant_quoteBooksWallsBand() public view {
        handler.checkAll();
    }
}

/// @notice Negative control: the same campaign must FAIL on a property that trading breaks, which proves Medusa reaches
///         real trades through this harness (target QuoteMedusaNegativeControl in a copy of medusa-quote.json).
contract QuoteMedusaNegativeControl is QuoteMedusa {
    function invariant_negativeControl_noTradeEverSucceeds() public view {
        assertInvariant(handler.trades() == 0, "negative control: a trade succeeded");
    }
}
