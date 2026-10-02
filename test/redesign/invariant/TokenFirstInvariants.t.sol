// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenFirstBase} from "../utils/TokenFirstBase.sol";
import {QuoteHandler} from "./QuoteHandler.sol";
import {CubitQuoteHook} from "../../../src/quote/CubitQuoteHook.sol";
import {CubitForgeV2} from "../../../src/periphery/CubitForgeV2.sol";
import {QuoteTaxes} from "../../../src/quote/QuoteTaxes.sol";

/// @notice The launchpad v3 under random sequences: four children of the Forge v3 on one PoolManager — ETH (quote
///         first, CubitQuoteHook), and USDC, WBTC and TSLAon (token first, CubitTokenFirstHook) — with different taxes,
///         random trades in the four modes, limited sales, deliveries, team claims and donations. Every action is
///         followed by QuoteHandler's invariant checks, in each child's orientation.
///         Large runs: FOUNDRY_INVARIANT_RUNS=<runs> FOUNDRY_INVARIANT_DEPTH=<depth> forge test --mc TokenFirstInvariants
contract TokenFirstInvariants is TokenFirstBase {
    QuoteHandler internal handler;

    function setUp() public override {
        super.setUp();
        CubitQuoteHook[] memory hooks = new CubitQuoteHook[](4);
        (Kid memory eth,) = _launchV3(alice, ETH, 0);
        taxes = QuoteTaxes.Taxes(0, 0, 0);
        (Kid memory usdc,) = _launchV3(alice, USDC, 0);
        taxes = QuoteTaxes.Taxes(100, 250, 700);
        (Kid memory wbtc,) = _launchV3(bob, WBTC, 0);
        taxes = QuoteTaxes.Taxes(500, 500, 2_000);
        (Kid memory tsla,) = _launchV3(alice, TSLAON, 0);
        (hooks[0], hooks[1], hooks[2], hooks[3]) = (CubitQuoteHook(address(eth.hook)), CubitQuoteHook(address(usdc.hook)),
            CubitQuoteHook(address(wbtc.hook)), CubitQuoteHook(address(tsla.hook)));
        handler = new QuoteHandler(manager, CubitForgeV2(address(forgeV3)), hooks);
        handler.markTokenFirst(address(usdc.hook));
        handler.markTokenFirst(address(wbtc.hook));
        handler.markTokenFirst(address(tsla.hook));
        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](13);
        s[0] = QuoteHandler.buyExactIn.selector;
        s[1] = QuoteHandler.buyExactIn.selector;
        s[2] = QuoteHandler.buyExactIn.selector;
        s[3] = QuoteHandler.buyExactOut.selector;
        s[4] = QuoteHandler.sellExactIn.selector;
        s[5] = QuoteHandler.sellExactIn.selector;
        s[6] = QuoteHandler.sellExactOut.selector;
        s[7] = QuoteHandler.rawSell.selector;
        s[8] = QuoteHandler.deliverAbsorbed.selector;
        s[9] = QuoteHandler.claimTeam.selector;
        s[10] = QuoteHandler.donateClaims.selector;
        s[11] = QuoteHandler.donateRaw.selector;
        s[12] = QuoteHandler.sellExactIn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    /// @dev The handler really trades on a token-first child: buys, sales and a limited sale.
    function test_HandlerTradesTokenFirst() public {
        handler.buyExactIn(1, 0, 1000e6);
        assertEq(handler.trades(), 1, "a buy did not trade");
        handler.sellExactIn(1, 0, 5_000);
        assertEq(handler.trades(), 2, "a sale did not trade");
        handler.rawSell(1, 0, 5_000, 100);
        assertEq(handler.trades(), 3, "a limited sale did not trade");
        handler.buyExactIn(0, 1, 0.1 ether);
        assertEq(handler.trades(), 4, "an ETH buy did not trade");
    }

    function invariant_booksWallsBand() public view {
        handler.checkAll();
    }

    function afterInvariant() public {
        emit log_named_uint("trades", handler.trades());
        emit log_named_uint("refused trades", handler.refusals());
        emit log_named_uint("walls crossed", handler.wallsCrossed());
        if (handler.calls() >= 64) assertGt(handler.trades(), 0, "a long run executed no trade");
    }
}
