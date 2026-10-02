// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuoteBase} from "../utils/QuoteBase.sol";
import {QuoteHandler} from "./QuoteHandler.sol";
import {CubitQuoteHook} from "../../../src/quote/CubitQuoteHook.sol";
import {QuoteTaxes} from "../../../src/quote/QuoteTaxes.sol";

/// @notice The launchpad v2 under random sequences: four children on one PoolManager (ETH, two USDC, WBTC), each with
///         its own taxes (CUBIT's, none, the maxima, an uneven set), random
///         trades in the four modes, limited sales, two-hop routes, deliveries, team claims and donations. Every action
///         is followed by the invariant checks of QuoteHandler.
///         Large runs: FOUNDRY_INVARIANT_RUNS=<runs> FOUNDRY_INVARIANT_DEPTH=<depth> forge test --mc QuoteInvariants
contract QuoteInvariants is QuoteBase {
    QuoteHandler internal handler;

    function setUp() public override {
        super.setUp();
        CubitQuoteHook[] memory hooks = new CubitQuoteHook[](4);
        // Each child with its own taxes: CUBIT's, none at all, the maxima, and an uneven set.
        (Child memory eth,) = _launch(alice, ETH, 0);
        taxes = QuoteTaxes.Taxes(0, 0, 0);
        (Child memory usdcA,) = _launch(alice, USDC, 0);
        taxes = QuoteTaxes.Taxes(500, 500, 2_000);
        (Child memory usdcB,) = _launch(bob, USDC, 0);
        taxes = QuoteTaxes.Taxes(100, 250, 700);
        (Child memory wbtc,) = _launch(alice, WBTC, 0);
        (hooks[0], hooks[1], hooks[2], hooks[3]) = (eth.hook, usdcA.hook, usdcB.hook, wbtc.hook);
        handler = new QuoteHandler(manager, forgeV2, hooks);
        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](15);
        s[0] = QuoteHandler.buyExactIn.selector;
        s[1] = QuoteHandler.buyExactIn.selector;
        s[2] = QuoteHandler.buyExactIn.selector;
        s[3] = QuoteHandler.buyExactOut.selector;
        s[4] = QuoteHandler.sellExactIn.selector;
        s[5] = QuoteHandler.sellExactIn.selector;
        s[6] = QuoteHandler.sellExactOut.selector;
        s[7] = QuoteHandler.rawSell.selector;
        s[8] = QuoteHandler.twoHop.selector;
        s[9] = QuoteHandler.deliverAbsorbed.selector;
        s[10] = QuoteHandler.claimTeam.selector;
        s[11] = QuoteHandler.donateClaims.selector;
        s[12] = QuoteHandler.donateRaw.selector;
        s[13] = QuoteHandler.sellExactIn.selector;
        s[14] = QuoteHandler.twoHop.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    /// @dev The handler really trades: a swap reverting inside its try/catch would make every campaign vacuous.
    function test_HandlerTrades() public {
        handler.buyExactIn(1, 0, 1000e6);
        assertEq(handler.trades(), 1, "a direct buy did not trade");
        handler.sellExactIn(1, 0, 5_000);
        assertEq(handler.trades(), 2, "a direct sale did not trade");
        handler.buyExactIn(2, 0, 1000e6);
        handler.twoHop(1, 2, 0, 5_000);
        assertEq(handler.twoHops(), 1, "a direct two-hop route did not go through");
    }

    /// Books, walls and band on every child, and an empty Forge.
    function invariant_booksWallsBand() public view {
        handler.checkAll();
    }

    /// The campaign actually trades: a handler whose actions all revert would prove nothing.
    function afterInvariant() public {
        emit log_named_uint("trades", handler.trades());
        emit log_named_uint("refused trades", handler.refusals());
        emit log_named_uint("walls crossed", handler.wallsCrossed());
        emit log_named_uint("two-hop routes", handler.twoHops());
        if (handler.calls() >= 64) assertGt(handler.trades(), 0, "a long run executed no trade");
    }
}
