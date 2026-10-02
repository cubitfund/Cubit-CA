// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";
import {MockQuote, MockNoReturnQuote, QuoteSwapper, RefusingGovernanceVault} from "./utils/QuoteMocks.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {CubitHook} from "../../src/CubitHook.sol";
import {CubitForge, CubitForgeToken} from "../../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../../src/periphery/CubitForgeV2.sol";
import {CubitGovernanceVault} from "../../src/periphery/CubitGovernanceVault.sol";
import {CubitQuoteHook} from "../../src/quote/CubitQuoteHook.sol";
import {ICubitQuoteHook} from "../../src/quote/ICubitQuoteHook.sol";
import {QuoteBandLib} from "../../src/quote/QuoteBandLib.sol";
import {QuoteTaxes} from "../../src/quote/QuoteTaxes.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";

import {QuoteBase} from "./utils/QuoteBase.sol";

/// @notice The launchpad v2 use cases.
contract QuoteLaunchpadTest is QuoteBase {
    using StateLibrary for IPoolManager;

    // ================================================================== construction

    function test_ConstructorFreezesTheTable() public {
        address[] memory q = forgeV2.quotes();
        uint256[] memory v = _values();
        assertEq(q.length, v.length);
        for (uint256 i; i < q.length; i++) assertEq(forgeV2.launchValue(q[i]), v[i], "launch value");
        assertEq(forgeV2.launchValue(makeAddr("other")), 0, "an unlisted quote has a value");
        assertEq(forgeV2.launchFee(), FEE);
        assertEq(forgeV2.governanceVault(), address(governanceVault));
        assertEq(address(forgeV2.hook()), address(hook));
        assertEq(forgeV2.hookCreationCodeHash(), keccak256(type(CubitQuoteHook).creationCode));
    }

    function test_ConstructorRejectsBadTables() public {
        address[] memory q = new address[](2);
        uint256[] memory v = new uint256[](2);
        (q[0], q[1], v[0], v[1]) = (USDC, USDC, 1e6, 1e6);
        vm.expectRevert(bytes("duplicate quote"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, v);

        (q[1], v[1]) = (makeAddr("no code"), 1e6);
        vm.expectRevert(bytes("quote missing"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, v);

        (q[1], v[1]) = (WBTC, 0);
        vm.expectRevert(bytes("invalid launch value"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, v);

        // 21M tokens for 1 base unit: the launch tick would be about 587k, inside the bound; 1e40 units is far outside.
        v[1] = 1e60;
        vm.expectRevert(bytes("invalid launch value"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, v);

        uint256[] memory short_ = new uint256[](1);
        vm.expectRevert(bytes("invalid quotes"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, short_);

        vm.expectRevert(bytes("invalid quotes"));
        new CubitForgeV2(hook, FEE, address(governanceVault), new address[](0), new uint256[](0));

        vm.expectRevert(bytes("zero fee"));
        new CubitForgeV2(hook, 0, address(governanceVault), _quotes(), _values());
    }

    function test_ValidLaunchValueBounds() public view {
        assertTrue(forgeV2.validLaunchValue(1), "1 base unit for 21M tokens is inside the bound");
        assertTrue(forgeV2.validLaunchValue(0.15e8));
        assertTrue(forgeV2.validLaunchValue(1_000_000 ether));
        assertFalse(forgeV2.validLaunchValue(0));
        assertFalse(forgeV2.validLaunchValue(1e60));
    }

    function test_HookRejectsAQuoteAboveTheToken() public {
        CubitForgeToken t = new CubitForgeToken("X", "X");
        // Any hook address will do: the ordering check comes before the permission check.
        address quote = address(uint160(address(t)) + 1);
        vm.etch(quote, hex"00");
        vm.expectRevert(ICubitQuoteHook.QuoteNotCurrency0.selector);
        new CubitQuoteHook(manager, t, childTeam, Currency.wrap(quote), 1e6, QuoteTaxes.cubit());
    }

    // ================================================================== launches

    function test_LaunchEveryQuote() public {
        address[] memory q = _quotes();
        for (uint256 i; i < q.length; i++) {
            uint256 fees0 = governanceVault.held(address(0));
            (Child memory c,) = _launch(alice, q[i], 0);
            assertTrue(c.hook.initialized(), "not initialized");
            assertEq(Currency.unwrap(c.key.currency0), q[i], "quote is not currency0");
            assertEq(Currency.unwrap(c.hook.quote()), q[i]);
            assertEq(c.hook.LAUNCH_QUOTE(), forgeV2.launchValue(q[i]));
            assertEq(c.hook.TEAM_ADDRESS(), childTeam);
            assertEq(c.hook.absorbedTokenSink(), address(governanceVault), "sink is not the governance vault");
            assertEq(governanceVault.held(address(0)) - fees0, FEE, "fee not locked");
            (, int24 upper, uint128 liquidity) = c.hook.band();
            assertGt(liquidity, 0, "empty band");
            assertLe(upper, _childTick(c), "band above the price");
            assertEq(c.token.balanceOf(address(c.hook)), 0, "the hook kept tokens");
            assertEq(c.token.balanceOf(address(manager)) + c.token.totalBurned(), c.token.TOTAL_SUPPLY(), "supply not in band");
            // The launch price is the launch value spread over the supply, to 1e-15 at least.
            uint256 price = QuoteBandLib.priceAtSqrt(c.hook.INITIAL_SQRT_PRICE());
            uint256 expected = forgeV2.launchValue(q[i]) * 1e36 / 21_000_000e18;
            assertApproxEqRel(price, expected, 1e3, "launch price");
            _assertChildBooks(c);
        }
        assertEq(forgeV2.launches(), q.length);
    }

    function test_LaunchRejects() public {
        (CubitForgeV2.LaunchParams memory p,,) = _params(alice, USDC, 0);
        bytes memory code = type(CubitQuoteHook).creationCode;
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("wrong payment"));
        forgeV2.launch{value: FEE + 1}(p, code);

        vm.prank(alice);
        vm.expectRevert(bytes("template mismatch"));
        forgeV2.launch{value: FEE}(p, type(CubitHook).creationCode);

        CubitForgeV2.LaunchParams memory other = _copy(p);
        other.quote = makeAddr("unlisted");
        vm.prank(alice);
        vm.expectRevert(bytes("quote not accepted"));
        forgeV2.launch{value: FEE}(other, code);

        other = _copy(p);
        other.team = address(0);
        vm.prank(alice);
        vm.expectRevert(bytes("invalid team"));
        forgeV2.launch{value: FEE}(other, code);

        other = _copy(p);
        other.symbol = "THIRTEEN_CHAR";
        vm.prank(alice);
        vm.expectRevert(bytes("invalid name"));
        forgeV2.launch{value: FEE}(other, code);

        // The salts are bound to the launcher: bob replaying alice's parameters gets other addresses, whose hook
        // address lacks the flags.
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        forgeV2.launch{value: FEE}(p, code);

        // An ETH pair takes the fee plus the buy, exactly.
        (CubitForgeV2.LaunchParams memory e,,) = _params(alice, ETH, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wrong payment"));
        forgeV2.launch{value: FEE}(e, code);
    }

    function _copy(CubitForgeV2.LaunchParams memory p) internal pure returns (CubitForgeV2.LaunchParams memory) {
        return CubitForgeV2.LaunchParams(p.name, p.symbol, p.team, p.quote, p.tokenSalt, p.hookSalt, p.buyAmount, p.taxes);
    }

    function test_TokenBelowQuoteReverts() public {
        (bytes32 tokenSalt, address predicted) = _tokenSalt(alice, TSLAON, "Child", "CHLD", true);
        assertLt(uint160(predicted), uint160(TSLAON));
        (bytes32 hookSalt,) = _hookSalt(alice, predicted, TSLAON, childTeam);
        CubitForgeV2.LaunchParams memory p = CubitForgeV2.LaunchParams({
            name: "Child", symbol: "CHLD", team: childTeam, quote: TSLAON,
            tokenSalt: tokenSalt, hookSalt: hookSalt, buyAmount: 0, taxes: taxes
        });
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("token sorts below quote"));
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    function test_InactiveWhenNotRegistered() public {
        CubitForgeV2 spare = new CubitForgeV2(hook, FEE, address(governanceVault), _quotes(), _values());
        CubitForgeV2.LaunchParams memory p;
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("Forge inactive"));
        spare.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    function test_LaunchWithBuyEveryQuote() public {
        address[] memory q = _quotes();
        // About 2.7% of the launch FDV, like CUBIT's 0.1 ETH dev buy on 3.75 ETH.
        for (uint256 i; i < q.length; i++) _launchWithBuy(q[i], forgeV2.launchValue(q[i]) * 27 / 1_000);
        assertEq(address(forgeV2).balance, 0, "the Forge kept ETH");
    }

    function _launchWithBuy(address quote, uint256 amount) internal {
        uint256 before = _balance(quote, alice);
        (Child memory c, uint256 out) = _launch(alice, quote, amount);
        assertGt(out, 0, "nothing bought");
        assertEq(c.token.balanceOf(alice), out, "tokens not delivered to the launcher");
        uint256 paidBack = quote == ETH ? FEE : 0;
        assertEq(before + amount + paidBack - _balance(quote, alice), amount + paidBack, "the launcher did not pay exactly the buy");
        assertEq(c.hook.teamAccrued(), FullMath.mulDivRoundingUp(amount, 300, 10_000), "buy not taxed 3%");
        assertEq(_balance(quote, address(forgeV2)), 0, "the Forge kept quote");
        assertEq(c.token.balanceOf(address(forgeV2)), 0, "the Forge kept tokens");
        _assertChildBooks(c);
    }

    /// @dev The launcher's buy is the first: nobody can trade the pool before it, and it pays the launch price.
    function test_LaunchBuyGetsTheLaunchPrice() public {
        (Child memory c, uint256 out) = _launch(alice, USDC, forgeV2.launchValue(USDC) / 100);
        // 1% of the FDV: net of the 3% tax it buys a little under 1% of the supply.
        uint256 onePercent = 210_000e18;
        assertLt(out, onePercent * 97 / 100, "bought more than the launch price allows");
        assertGt(out, onePercent * 95 / 100, "bought far less than the launch price gives");
        _assertChildBooks(c);
    }

    // ================================================================== trading

    function test_TradingCycleEveryQuote() public {
        address[] memory q = _quotes();
        // About a quarter of the launch FDV.
        for (uint256 i; i < q.length; i++) _tradingCycle(q[i], forgeV2.launchValue(q[i]) * 27 / 100);
    }

    function _tradingCycle(address quote, uint256 buyIn) internal {
        (Child memory c,) = _launch(alice, quote, 0);
        uint256 got = _buyChild(c, bob, buyIn);
        assertGt(got, 0);
        assertEq(c.hook.teamAccrued(), FullMath.mulDivRoundingUp(buyIn, 300, 10_000), "buy tax");
        _assertChildBooks(c);

        // A partial sale funds one wall with its 12%, placed under the price at the 40/60 target.
        _sellChild(c, bob, got / 10);
        assertEq(c.hook.activeWallCount(), 1, "no wall placed");
        (bool exists, int24 lower) = c.hook.nearestWallTick();
        assertTrue(exists);
        assertGt(lower, _childTick(c), "the wall is not under the market");
        _assertTargetWall(c, lower);
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);

        // Selling the rest crosses that wall: its tokens wait for delivery to the governance vault.
        _sellChild(c, bob, c.token.balanceOf(bob));
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
        uint256 absorbed = c.hook.pendingAbsorbedTokens();
        assertGt(absorbed, 0, "the crossed wall absorbed nothing");
        c.hook.deliverAbsorbed();
        assertEq(governanceVault.held(address(c.token)), absorbed, "absorbed tokens not locked in the governance vault");
        assertEq(c.token.balanceOf(address(governanceVault)), absorbed);
        _assertChildBooks(c);

        // The team is paid in the quote.
        uint256 due = c.hook.teamAccrued();
        uint256 before = _balance(quote, childTeam);
        c.hook.claimTeam();
        assertEq(_balance(quote, childTeam) - before, due, "team not paid in the quote");
        assertEq(c.hook.teamAccrued(), 0);
        _assertChildBooks(c);
    }

    /// @dev The wall's upper price edge sits at the 40/60 target or one spacing under it: the price of its lower tick
    ///      (the highest the wall pays) is below the target and within 0.2% of it.
    function _assertTargetWall(Child memory c, int24 lower) internal view {
        uint256 launchPrice = QuoteBandLib.priceAtSqrt(c.hook.INITIAL_SQRT_PRICE());
        uint256 current = QuoteBandLib.priceAtSqrt(_childSqrtP(c));
        uint256 target = (current * 4_000 + launchPrice * 6_000) / 10_000;
        if (current <= launchPrice) target = current * 9_900 / 10_000;
        uint256 wallPrice = QuoteBandLib.priceAtSqrt(TickMath.getSqrtPriceAtTick(lower));
        // The target was computed at the price after the sale, before the wall was placed: the same price as now.
        assertLe(wallPrice, target, "the wall pays more than the target");
        assertGe(wallPrice, target * 9_980 / 10_000, "the wall is more than two spacings under the target");
    }

    /// @dev The reason for QuoteBandLib: with a WBTC quote, BandLib's 1e18 prices round the launch price to zero and
    ///      its target lands nowhere near 40/60.
    function test_BandLibLosesAWbtcPrice() public {
        (Child memory c,) = _launch(alice, WBTC, 0);
        _buyChild(c, bob, 0.05e8);
        uint160 sqrtP = _childSqrtP(c);
        assertEq(BandLib.ethPerCubitAtSqrt(c.hook.INITIAL_SQRT_PRICE()), 0, "BandLib keeps a WBTC launch price");
        int24 precise = QuoteBandLib.retracementWallTarget(c.hook.INITIAL_SQRT_PRICE(), sqrtP, 10);
        int24 coarse = BandLib.retracementWallTarget(c.hook.INITIAL_SQRT_PRICE(), sqrtP, 10);
        assertGt(coarse - precise, 1_000, "BandLib's WBTC target should be off by more than 10%");
    }

    function test_ExactOutputModesAreTaxed() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        // Exact-output buy: 1M tokens.
        _mintQuote(USDC, bob, forgeV2.launchValue(USDC));
        _approve(USDC, bob, address(swapper));
        vm.prank(bob);
        BalanceDelta d = swapper.swap(c.key, true, int256(1_000_000e18));
        uint256 paid = uint256(uint128(-d.amount0()));
        assertEq(c.token.balanceOf(bob), 1_000_000e18);
        uint256 tax = c.hook.teamAccrued();
        assertEq(tax, FullMath.mulDivRoundingUp(paid - tax, 300, 9_700), "exact-output buy tax");
        // Exact-output sale: 100 USDC net.
        vm.prank(bob);
        c.token.approve(address(swapper), type(uint256).max);
        uint256 before = MockQuote(USDC).balanceOf(bob);
        vm.prank(bob);
        swapper.swap(c.key, false, int256(100e6));
        assertEq(MockQuote(USDC).balanceOf(bob) - before, 100e6, "exact-output sale did not net the amount");
        uint256 sellTax = FullMath.mulDivRoundingUp(100e6, 1_500, 8_500);
        assertEq(c.hook.teamAccrued() - tax, sellTax * 300 / 1_500, "exact-output sale team share");
        assertEq(c.hook.activeWallCount(), 1, "exact-output sale placed no wall");
        _assertChildBooks(c);
    }

    function test_NobodyElseAddsLiquidity() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint160 sqrtPrice = c.hook.INITIAL_SQRT_PRICE();
        vm.expectRevert();
        manager.initialize(c.key, sqrtPrice);
        // The PoolManager calls this guard for any third party's modifyLiquidity.
        ModifyLiquidityParams memory params;
        vm.prank(address(manager));
        vm.expectRevert(ICubitQuoteHook.ExternalLiquidityForbidden.selector);
        c.hook.beforeAddLiquidity(alice, c.key, params, "");
    }

    /// @dev Random buys and sales on a 6-decimal and an 8-decimal child: books exact, no crossed wall left, every
    ///      absorbed token delivered, team paid to the unit.
    function testFuzz_RandomTrading(uint256 seed) public {
        (Child memory usdc,) = _launch(alice, USDC, 0);
        (Child memory wbtc,) = _launch(alice, WBTC, 0);
        _randomTrading(usdc, seed, forgeV2.launchValue(USDC));
        _randomTrading(wbtc, uint256(keccak256(abi.encode(seed))), forgeV2.launchValue(WBTC));
    }

    function _randomTrading(Child memory c, uint256 seed, uint256 fdv) internal {
        for (uint256 i; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (seed % 3 != 0 || c.token.balanceOf(bob) == 0) {
                // Buys from a millionth to a quarter of the launch FDV.
                uint256 amount = bound(seed >> 8, fdv / 1_000_000 + 1, fdv / 4);
                _buyChild(c, bob, amount);
            } else {
                uint256 held = c.token.balanceOf(bob);
                _sellChild(c, bob, bound(seed >> 8, 1, held));
            }
            _assertChildBooks(c);
            _assertNoCrossedChildWall(c);
        }
        c.hook.deliverAbsorbed();
        assertEq(c.hook.pendingAbsorbedTokens(), 0);
        uint256 due = c.hook.teamAccrued();
        uint256 before = _balance(c.quote, childTeam);
        c.hook.claimTeam();
        assertEq(_balance(c.quote, childTeam) - before, due);
        _assertChildBooks(c);
    }

    // ================================================================== launch bounds and refusals

    /// @dev The accepted launch range keeps the whole supply in the band at both ends; below it, refused.
    function test_LaunchBoundsKeepTheWholeBand() public {
        // Tick about -292,000 (dearest accepted token) and about +587,000 (cheapest).
        assertTrue(forgeV2.validLaunchValue(1e38), "the dear end is refused");
        assertFalse(forgeV2.validLaunchValue(1e39), "a launch tick under -300,000 is accepted");
        MockQuote dear = new MockQuote("DEAR", 18);
        MockQuote cheap = new MockQuote("CHEAP", 18);
        address[] memory q = new address[](2);
        uint256[] memory v = new uint256[](2);
        (q[0], q[1], v[0], v[1]) = (address(dear), address(cheap), 1e38, 1);
        _useForge(new CubitForgeV2(hook, FEE, address(governanceVault), q, v));
        for (uint256 i; i < 2; i++) {
            (Child memory c,) = _launch(alice, q[i], 0);
            (,, uint128 liquidity) = c.hook.band();
            assertGt(liquidity, 0);
            assertGe(c.token.balanceOf(address(manager)), c.hook.MIN_POOL_SUPPLY(), "the band took less than 80%");
            assertLt(c.token.totalBurned(), 1e18, "the bootstrap burned more than rounding dust");
            _assertChildBooks(c);
        }
        CubitForgeToken t = new CubitForgeToken("X", "X");
        vm.expectRevert(ICubitQuoteHook.UnexpectedInitialPrice.selector);
        new CubitQuoteHook(manager, t, childTeam, Currency.wrap(address(0)), 1e39, QuoteTaxes.cubit());
    }

    /// @dev The launcher's buy must fill completely. At the cheapest accepted launch price, a buy of more
    ///      quote than the whole band can absorb stops at the price limit: the launch reverts instead of charging
    ///      the whole tax on a partial fill.
    function test_LaunchBuyMustFill() public {
        MockQuote cheap = new MockQuote("CHEAP", 18);
        address[] memory q = new address[](1);
        uint256[] memory v = new uint256[](1);
        (q[0], v[0]) = (address(cheap), 1);
        _useForge(new CubitForgeV2(hook, FEE, address(governanceVault), q, v));
        uint256 huge = uint256(uint128(type(int128).max));
        (CubitForgeV2.LaunchParams memory p,,) = _params(alice, address(cheap), huge);
        cheap.mint(alice, huge);
        _approve(address(cheap), alice, address(forgeV2));
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("buy not filled"));
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    /// @dev A buy amount beyond int128 is refused before any signed conversion.
    function test_BuyTooLarge() public {
        (CubitForgeV2.LaunchParams memory p,,) = _params(alice, USDC, 0);
        p.buyAmount = uint256(uint128(type(int128).max)) + 1;
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("buy too large"));
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        p.buyAmount = type(uint256).max;
        vm.prank(alice);
        vm.expectRevert(bytes("buy too large"));
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    /// @dev A team that could never pass the taxes on is refused, including the child token itself.
    function test_UnusableTeamsAreRefused() public {
        address[] memory bad = new address[](4);
        (bad[0], bad[1], bad[2], bad[3]) = (address(forgeV2), address(manager), address(governanceVault), address(hook));
        vm.deal(alice, 1 ether);
        for (uint256 i; i < bad.length; i++) {
            (bytes32 tokenSalt, address predicted) = _tokenSalt(alice, USDC, "Child", "CHLD", false);
            CubitForgeV2.LaunchParams memory p = CubitForgeV2.LaunchParams("Child", "CHLD", bad[i], USDC, tokenSalt, 0, 0, taxes);
            predicted;
            vm.prank(alice);
            vm.expectRevert(bytes("invalid team"));
            forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        }
        (bytes32 salt, address token_) = _tokenSalt(alice, USDC, "Child", "CHLD", false);
        CubitForgeV2.LaunchParams memory self = CubitForgeV2.LaunchParams("Child", "CHLD", token_, USDC, salt, 0, 0, taxes);
        vm.prank(alice);
        vm.expectRevert(bytes("invalid team"));
        forgeV2.launch{value: FEE}(self, type(CubitQuoteHook).creationCode);
    }

    function _useForge(CubitForgeV2 next) internal {
        forgeV2 = next;
        vm.startPrank(team);
        registry.setForge(address(next));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
    }

    // ================================================================== launch edge cases

    /// @dev At most 16 quotes.
    function test_TooManyQuotes() public {
        address[] memory q = new address[](17);
        uint256[] memory v = new uint256[](17);
        for (uint256 i; i < 17; i++) (q[i], v[i]) = (address(new MockQuote("Q", 6)), 1e10);
        vm.expectRevert(bytes("invalid quotes"));
        new CubitForgeV2(hook, FEE, address(governanceVault), q, v);
    }

    /// @dev Registered but not activated (setForge clears the bit): launches refused.
    function test_RegisteredButInactive() public {
        CubitForgeV2 next = new CubitForgeV2(hook, FEE, address(governanceVault), _quotes(), _values());
        vm.prank(team);
        registry.setForge(address(next));
        assertEq(registry.enabledFeatures() & FORGE_BIT, 0);
        forgeV2 = next;
        (CubitForgeV2.LaunchParams memory p,,) = _params(alice, USDC, 0);
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("Forge inactive"));
        next.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    /// @dev Two launchers, same name, same quote, same block: both launch.
    function test_TwoLaunchersSameBlock() public {
        (Child memory a,) = _launch(alice, USDC, 0);
        (Child memory b,) = _launch(bob, USDC, 0);
        assertTrue(address(a.token) != address(b.token) && address(a.hook) != address(b.hook));
        assertEq(forgeV2.launches(), 2);
    }

    /// @dev The same launch sent twice: the second reverts and leaves nothing behind.
    function test_SameLaunchTwiceLeavesNothing() public {
        (CubitForgeV2.LaunchParams memory p,,) = _params(alice, USDC, 0);
        vm.deal(alice, 2 * FEE);
        vm.prank(alice);
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        uint256 fees = governanceVault.held(address(0));
        uint256 tranches = governanceVault.trancheCount(address(0));
        vm.prank(alice);
        vm.expectRevert();
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        assertEq(forgeV2.launches(), 1);
        assertEq(governanceVault.held(address(0)), fees, "a failed launch paid a fee");
        assertEq(governanceVault.trancheCount(address(0)), tranches);
        assertEq(alice.balance, FEE, "the failed launch kept the ETH");
    }

    /// @dev Without an allowance the launch reverts entirely: no token, no hook, no fee.
    function test_MissingAllowanceLeavesNothing() public {
        (CubitForgeV2.LaunchParams memory p, address token_, address hook_) = _params(alice, USDC, 100e6);
        _mintQuote(USDC, alice, 100e6);
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert();
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        assertEq(token_.code.length, 0, "a token was left behind");
        assertEq(hook_.code.length, 0, "a hook was left behind");
        assertEq(forgeV2.launches(), 0);
        assertEq(governanceVault.held(address(0)), 0);
    }

    /// @dev A governance vault that refuses the fee rolls the whole launch back, after the pool was created.
    function test_RefusingGovernanceVaultRollsBack() public {
        RefusingGovernanceVault refusing = new RefusingGovernanceVault();
        _useForge(new CubitForgeV2(hook, FEE, address(refusing), _quotes(), _values()));
        (CubitForgeV2.LaunchParams memory p, address token_, address hook_) = _params(alice, USDC, 0);
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert(bytes("refused"));
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        assertEq(token_.code.length, 0);
        assertEq(hook_.code.length, 0);
        assertEq(forgeV2.launches(), 0);
    }

    /// @dev Nobody can initialize the pool before the launch deploys its hook.
    function test_NoPoolBeforeTheLaunch() public {
        (CubitForgeV2.LaunchParams memory p, address token_, address hook_) = _params(alice, USDC, 0);
        PoolKey memory k = PoolKey(Currency.wrap(USDC), Currency.wrap(token_), 100, 10, IHooks(hook_));
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        vm.deal(alice, FEE);
        vm.prank(alice);
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    /// @dev The child hook refuses any other pool key.
    function test_ChildHookRefusesForeignPools() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        PoolKey memory k = c.key;
        k.fee = 3000;
        uint160 sqrtPrice = c.hook.INITIAL_SQRT_PRICE();
        vm.expectRevert();
        manager.initialize(k, sqrtPrice);
        k = c.key;
        k.currency0 = Currency.wrap(WBTC);
        vm.expectRevert();
        manager.initialize(k, sqrtPrice);
    }

    // ================================================================== trading edge cases

    /// @dev One-unit trades neither revert nor break the books. A one-unit buy is untaxed
    ///      (the tax would be the whole amount): documented, worth less than its gas.
    function test_TinyTrades() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 got = _buyChild(c, bob, 1);
        assertEq(c.hook.teamAccrued(), 0, "a one-unit buy was taxed");
        _buyChild(c, bob, 2);
        assertEq(c.hook.teamAccrued(), 1, "a two-unit buy pays one unit");
        got = _buyChild(c, bob, 1_000e6);
        for (uint256 i = 1; i <= 5; i++) _sellChild(c, bob, i);
        _sellChild(c, bob, 1e12);
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
    }

    /// @dev Dust sales on an 8-decimal quote: the dust waits, nothing reverts.
    function test_WbtcDustSales() public {
        (Child memory c,) = _launch(alice, WBTC, 0);
        uint256 got = _buyChild(c, bob, 0.01e8);
        for (uint256 i; i < 20; i++) _sellChild(c, bob, got / 10_000);
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
    }

    /// @dev At or below the launch price, a sale's wall goes 1% under the price. Every child token starts
    ///      in the band, which holds no liquidity under the launch price: a sale can only end there with a price
    ///      limit, after selling back into the band. Bob sells back what he bought plus dealt tokens (the supply
    ///      check is skipped on purpose) and stops 2,000 ticks under the launch price.
    function test_WallOnePercentUnderBelowLaunch() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 got = _buyChild(c, bob, 3_000e6);
        deal(address(c.token), bob, got + 100_000e18);
        int24 launchTick = TickMath.getTickAtSqrtPrice(c.hook.INITIAL_SQRT_PRICE());
        uint160 limit = TickMath.getSqrtPriceAtTick(launchTick + 2_000);
        int256 amount = -int256(c.token.balanceOf(bob));
        vm.startPrank(bob);
        c.token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            c.key,
            SwapParams({zeroForOne: false, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        uint256 current = QuoteBandLib.priceAtSqrt(_childSqrtP(c));
        assertLt(current, QuoteBandLib.priceAtSqrt(c.hook.INITIAL_SQRT_PRICE()), "not under the launch price");
        (bool exists, int24 lower) = c.hook.nearestWallTick();
        assertTrue(exists, "no wall under launch");
        uint256 wallPrice = QuoteBandLib.priceAtSqrt(TickMath.getSqrtPriceAtTick(lower));
        uint256 target = current * 9_900 / 10_000;
        assertLe(wallPrice, target, "the wall is closer than 1%");
        assertGe(wallPrice, target * 9_980 / 10_000, "the wall is more than two spacings under 1%");
    }

    /// @dev An enormous buy followed by selling everything back: no overflow, no revert, exact books.
    function test_ExtremePrices() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 got = _buyChild(c, bob, 1e30);
        assertGt(got, 20_000_000e18, "the whale did not take nearly the whole band");
        _sellChild(c, bob, got / 3);
        _sellChild(c, bob, c.token.balanceOf(bob));
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
    }

    /// @dev Many walls crossed by one sale. Each rising step places a wall at a new tick; one sale then
    ///      crosses them all. Gas is reported (not isolated: `forge test --isolate` gives the cold figure).
    function test_ManyWallsCrossedInOneSale() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 held;
        for (uint256 i; i < 40; i++) {
            held += _buyChild(c, bob, 300e6);
            uint256 part = held / 50;
            _sellChild(c, bob, part);
            held -= part;
        }
        uint256 walls = c.hook.activeWallCount();
        assertGt(walls, 30, "not enough distinct walls");
        vm.prank(bob);
        c.token.approve(address(swapper), type(uint256).max);
        int256 all = -int256(c.token.balanceOf(bob));
        uint256 gasBefore = gasleft();
        vm.prank(bob);
        swapper.swap(c.key, false, all);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("walls crossed in one sale", walls - c.hook.activeWallCount());
        emit log_named_uint("gas of that sale", used);
        assertLt(used, 30_000_000, "one sale over 30M gas");
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
    }

    /// @dev Child A -> quote -> child B in one unlock: each child taxes once, the quote nets
    ///      inside the PoolManager, and a third child sharing the quote does not move.
    function test_MultiHopBetweenChildren() public {
        (Child memory a,) = _launch(alice, USDC, 0);
        (Child memory b,) = _launch(bob, USDC, 0);
        (Child memory other,) = _launch(address(0xC0FFEE), USDC, 0);
        uint256 got = _buyChild(a, bob, 3_000e6);
        uint256 teamA = a.hook.teamAccrued();
        uint256 teamB = b.hook.teamAccrued();
        uint160 otherPrice = _childSqrtP(other);
        uint256 usdcBefore = MockQuote(USDC).balanceOf(bob);
        vm.prank(bob);
        a.token.approve(address(swapper), type(uint256).max);
        vm.prank(bob);
        uint256 out = swapper.swapThrough(a.key, b.key, got / 2);
        assertGt(out, 0);
        assertEq(b.token.balanceOf(bob), out);
        assertEq(MockQuote(USDC).balanceOf(bob), usdcBefore, "the quote left the PoolManager");
        assertGt(a.hook.teamAccrued(), teamA, "child A did not tax the sale");
        assertGt(b.hook.teamAccrued(), teamB, "child B did not tax the buy");
        assertEq(a.hook.activeWallCount(), 1, "child A's sale placed no wall");
        assertEq(_childSqrtP(other), otherPrice, "an uninvolved child moved");
        _assertChildBooks(a);
        _assertChildBooks(b);
        _assertChildBooks(other);
    }

    // ================================================================== donations

    /// @dev Raw quote, raw tokens, ETH and ERC-6909 claims given to the hook change neither prices nor books; the
    ///      surplus stays where it was given, never spent by the protocol.
    function test_DonationsChangeNothing() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 got = _buyChild(c, bob, 3_000e6);
        uint160 before = _childSqrtP(c);
        // Raw donations.
        _mintQuote(USDC, address(c.hook), 7e6);
        vm.prank(bob);
        c.token.transfer(address(c.hook), 1e18);
        vm.deal(address(c.hook), 1 ether);
        // An ERC-6909 claim donation.
        PoolClaimsTest claims = new PoolClaimsTest(manager);
        _mintQuote(USDC, bob, 5e6);
        _approve(USDC, bob, address(claims));
        vm.prank(bob);
        claims.deposit(Currency.wrap(USDC), bob, 5e6);
        vm.prank(bob);
        manager.transfer(address(c.hook), uint256(uint160(USDC)), 5e6);
        assertEq(_childSqrtP(c), before, "a donation moved the price");

        _sellChild(c, bob, got / 10);
        _sellChild(c, bob, c.token.balanceOf(bob));
        c.hook.deliverAbsorbed();
        c.hook.claimTeam();
        uint256 quoteId = uint256(uint160(USDC));
        assertEq(
            manager.balanceOf(address(c.hook), quoteId),
            c.hook.pendingFloorQuote() + c.hook.teamAccrued() + c.hook.wallIdleQuote() + 5e6,
            "the donated claims were spent or lost"
        );
        assertEq(MockQuote(USDC).balanceOf(address(c.hook)), 7e6, "the raw quote moved");
        assertEq(c.token.balanceOf(address(c.hook)), 1e18, "the raw tokens moved");
        assertEq(address(c.hook).balance, 1 ether);
        _assertWallIndex(c);
    }

    /// @dev PoolManager.donate is open (the hook's donate flags are off). It pays the in-range position and
    ///      leaves the hook's books intact.
    function test_NativeDonate() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        _buyChild(c, bob, 3_000e6);
        PoolDonateTest donor = new PoolDonateTest(manager);
        _mintQuote(USDC, bob, 10e6);
        _approve(USDC, bob, address(donor));
        vm.prank(bob);
        donor.donate(c.key, 10e6, 0, "");
        _assertChildBooks(c);
        _sellChild(c, bob, c.token.balanceOf(bob));
        _assertChildBooks(c);
    }

    // ================================================================== governance vault

    function test_GovernanceVaultTranchesSumToHeld() public {
        for (uint256 i; i < 3; i++) {
            (Child memory c,) = _launch(i == 0 ? alice : i == 1 ? bob : childTeam, i == 2 ? WBTC : USDC, 0);
            _tradingCycleOn(c);
        }
        address[] memory assets = new address[](1);
        assets[0] = address(0);
        uint256 sum;
        for (uint256 t = governanceVault.nextTranche(address(0)); t < governanceVault.trancheCount(address(0)); t++) {
            (uint256 amount,) = governanceVault.tranche(address(0), t);
            sum += amount;
        }
        assertEq(sum, governanceVault.held(address(0)), "tranches do not sum to held");
        assertLe(governanceVault.held(address(0)), address(governanceVault).balance);
    }

    function _tradingCycleOn(Child memory c) internal {
        uint256 got = _buyChild(c, bob, forgeV2.launchValue(c.quote) / 5);
        _sellChild(c, bob, got / 10);
        _sellChild(c, bob, c.token.balanceOf(bob));
        uint256 absorbed = c.hook.pendingAbsorbedTokens();
        c.hook.deliverAbsorbed();
        assertEq(governanceVault.held(address(c.token)), absorbed);
    }

    // ================================================================== taxes chosen at launch

    /// @dev The rates a launcher chooses are frozen in its child: none at all, CUBIT's, or the maxima.
    function test_TaxesChosenAtLaunch() public {
        QuoteTaxes.Taxes[3] memory sets = [
            QuoteTaxes.Taxes(0, 0, 0), QuoteTaxes.cubit(), QuoteTaxes.Taxes(500, 500, 2_000)
        ];
        for (uint256 i; i < sets.length; i++) {
            taxes = sets[i];
            (Child memory c,) = _launch(i == 0 ? alice : i == 1 ? bob : childTeam, USDC, 0);
            assertEq(c.hook.BUY_TAX_BPS(), taxes.buyTeamBps);
            assertEq(c.hook.SELL_TEAM_BPS(), taxes.sellTeamBps);
            assertEq(c.hook.SELL_FLOOR_BPS(), taxes.sellWallBps);
            assertEq(c.hook.SELL_TAX_BPS(), uint256(taxes.sellTeamBps) + taxes.sellWallBps);
            _taxCycle(c, 3_000e6);
        }
    }

    /// @dev Exact rates on a buy, a partial sale and the rest sold back; walls only when the wall share is not zero.
    function _taxCycle(Child memory c, uint256 buyIn) internal {
        uint256 got = _buyChild(c, bob, buyIn);
        uint256 buyTax = FullMath.mulDivRoundingUp(buyIn, c.hook.BUY_TAX_BPS(), 10_000);
        assertEq(c.hook.teamAccrued(), buyTax, "buy tax");
        uint256 quoteOut = _sellChild(c, bob, got / 10);
        uint256 sellTax = c.hook.teamAccrued() - buyTax + c.hook.pendingFloorQuote() + _wallQuote(c);
        uint256 gross = quoteOut + sellTax;
        assertEq(sellTax, FullMath.mulDivRoundingUp(gross, c.hook.SELL_TAX_BPS(), 10_000), "sell tax");
        assertEq(c.hook.teamAccrued() - buyTax, sellTax * c.hook.SELL_TEAM_BPS() / (c.hook.SELL_TAX_BPS() == 0 ? 1 : c.hook.SELL_TAX_BPS()), "team share");
        assertEq(c.hook.activeWallCount(), c.hook.SELL_FLOOR_BPS() == 0 ? 0 : 1, "wall placement");
        _sellChild(c, bob, c.token.balanceOf(bob));
        _assertChildBooks(c);
        _assertNoCrossedChildWall(c);
    }

    /// @dev Quote the walls received from sales: what was placed (`fundedQuote`, exact) and what still waits.
    function _wallQuote(Child memory c) internal view returns (uint256 funded) {
        for (uint256 id; id < c.hook.wallCount(); id++) {
            (,,, uint256 f) = c.hook.walls(id);
            funded += f;
        }
    }

    function test_InvalidTaxesRefused() public {
        QuoteTaxes.Taxes[4] memory bad = [
            QuoteTaxes.Taxes(501, 0, 0), QuoteTaxes.Taxes(0, 501, 0), QuoteTaxes.Taxes(0, 0, 2_001),
            QuoteTaxes.Taxes(0, 500, 2_001)
        ];
        vm.deal(alice, 1 ether);
        for (uint256 i; i < bad.length; i++) {
            (CubitForgeV2.LaunchParams memory p,,) = _params(alice, USDC, 0);
            p.taxes = bad[i];
            vm.prank(alice);
            vm.expectRevert(bytes("invalid taxes"));
            forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        }
        // 5% + 20% is the most a sale can pay; anything above is refused by the hook itself too.
        assertTrue(QuoteTaxes.valid(QuoteTaxes.Taxes(500, 500, 2_000)));
        assertFalse(QuoteTaxes.valid(QuoteTaxes.Taxes(0, 501, 2_000)));
        CubitForgeToken t = new CubitForgeToken("X", "X");
        vm.expectRevert(ICubitQuoteHook.InvalidTaxes.selector);
        new CubitQuoteHook(manager, t, childTeam, Currency.wrap(address(0)), 3.75 ether, QuoteTaxes.Taxes(0, 0, 2_001));
    }

    /// @dev Any valid rates: exact taxes, exact books, and walls only when the wall share is not zero.
    function testFuzz_AnyValidTaxes(uint16 buyTeam, uint16 sellTeam, uint16 sellWall, uint256 buyIn) public {
        taxes = QuoteTaxes.Taxes(
            uint16(bound(buyTeam, 0, 500)), uint16(bound(sellTeam, 0, 500)), uint16(bound(sellWall, 0, 2_000))
        );
        (Child memory c,) = _launch(alice, WBTC, 0);
        _taxCycle(c, bound(buyIn, 0.001e8, 0.05e8));
    }

    /// @dev Exact-output buys and sales at any valid rates: taxes exact, split exact, walls only with a wall share.
    function testFuzz_ExactOutputAnyTaxes(uint16 buyTeam, uint16 sellTeam, uint16 sellWall, uint256 tokens) public {
        taxes = QuoteTaxes.Taxes(
            uint16(bound(buyTeam, 0, 500)), uint16(bound(sellTeam, 0, 500)), uint16(bound(sellWall, 0, 2_000))
        );
        (Child memory c,) = _launch(alice, USDC, 0);
        tokens = bound(tokens, 1_000e18, 2_000_000e18);
        _mintQuote(USDC, bob, forgeV2.launchValue(USDC));
        _approve(USDC, bob, address(swapper));
        vm.prank(bob);
        BalanceDelta d = swapper.swap(c.key, true, int256(tokens));
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 buyTax = c.hook.teamAccrued();
        uint256 b = c.hook.BUY_TAX_BPS();
        assertEq(buyTax, b == 0 ? 0 : FullMath.mulDivRoundingUp(paid - buyTax, b, 10_000 - b), "exact-output buy tax");

        vm.prank(bob);
        c.token.approve(address(swapper), type(uint256).max);
        uint256 net = paid / 4; // well within what the tokens just bought are worth, whatever the taxes
        vm.prank(bob);
        swapper.swap(c.key, false, int256(net));
        uint256 st = c.hook.SELL_TAX_BPS();
        uint256 sellTax = st == 0 ? 0 : FullMath.mulDivRoundingUp(net, st, 10_000 - st);
        uint256 toTeam = st == 0 ? 0 : sellTax * c.hook.SELL_TEAM_BPS() / st;
        assertEq(c.hook.teamAccrued() - buyTax, toTeam, "exact-output sale team share");
        assertEq(c.hook.pendingFloorQuote() + _wallQuote(c), sellTax - toTeam, "exact-output sale wall share");
        assertEq(c.hook.activeWallCount(), c.hook.SELL_FLOOR_BPS() == 0 ? 0 : 1, "wall placement");
        _assertChildBooks(c);
    }

    /// @dev Each bound plus one, straight against the hook's constructor. (5% team + 20% walls is exactly the 25% sale
    ///      maximum, so the total bound never binds on its own; it stays as a guard.)
    function test_HookRefusesEachBoundPlusOne() public {
        QuoteTaxes.Taxes[3] memory bad =
            [QuoteTaxes.Taxes(501, 0, 0), QuoteTaxes.Taxes(0, 501, 0), QuoteTaxes.Taxes(0, 0, 2_001)];
        for (uint256 i; i < bad.length; i++) {
            CubitForgeToken t = new CubitForgeToken("X", "X");
            vm.expectRevert(ICubitQuoteHook.InvalidTaxes.selector);
            new CubitQuoteHook(manager, t, childTeam, Currency.wrap(address(0)), 3.75 ether, bad[i]);
        }
    }

    /// @dev The rates are part of the hook's init code: the hook address changes with each of them, the token address
    ///      does not. Salts mined for one set of rates cannot launch another.
    function test_HookAddressCommitsToTheTaxes() public {
        (CubitForgeV2.LaunchParams memory p, address token_, address hook_) = _params(alice, USDC, 0);
        QuoteTaxes.Taxes[3] memory others =
            [QuoteTaxes.Taxes(301, 300, 1_200), QuoteTaxes.Taxes(300, 301, 1_200), QuoteTaxes.Taxes(300, 300, 1_201)];
        for (uint256 i; i < others.length; i++) {
            taxes = others[i];
            (, address otherToken, address otherHook) = _params(alice, USDC, 0);
            assertEq(otherToken, token_, "the token address depends on the taxes");
            assertTrue(otherHook != hook_, "the hook address does not commit to the taxes");
        }
        p.taxes = others[0];
        vm.deal(alice, FEE);
        vm.prank(alice);
        vm.expectRevert();
        forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
    }

    /// @dev A team that refuses ETH cannot be paid, but the child keeps trading and its due is kept.
    function test_TeamRefusingEthKeepsTrading() public {
        childTeam = address(new RefusingGovernanceVault()); // any contract without receive()
        (Child memory c,) = _launch(alice, ETH, 0);
        uint256 got = _buyChild(c, bob, 1 ether);
        uint256 due = c.hook.teamAccrued();
        vm.expectRevert();
        c.hook.claimTeam();
        assertEq(c.hook.teamAccrued(), due, "the due was lost");
        _sellChild(c, bob, got);
        _assertChildBooks(c);
    }

    // ================================================================== gaps found by slither-mutate

    /// @dev Only the PoolManager may call the Forge back: nobody can make it pull quote from a launcher's allowance.
    function test_UnlockCallbackOnlyFromThePoolManager() public {
        PoolKey memory k = c0Key();
        bytes memory data = abi.encode(k, alice, uint256(1e6));
        vm.prank(bob);
        vm.expectRevert(bytes("not pool manager"));
        forgeV2.unlockCallback(data);
    }

    function c0Key() internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDC), Currency.wrap(address(0xdead)), 100, 10, IHooks(address(0)));
    }

    /// @dev The event the app lists launches from carries exactly what happened.
    function test_ChildLaunchedEvent() public {
        (CubitForgeV2.LaunchParams memory p, address token_, address hook_) = _params(alice, USDC, 150e6);
        _mintQuote(USDC, alice, 150e6);
        _approve(USDC, alice, address(forgeV2));
        vm.deal(alice, FEE);
        vm.expectEmit(true, true, true, false, address(forgeV2));
        emit CubitForgeV2.ChildLaunched(token_, hook_, alice, USDC, childTeam, FEE, 150e6, 0);
        vm.recordLogs();
        vm.prank(alice);
        (,, uint256 out) = forgeV2.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(forgeV2)) continue;
            (address quote, address team_, uint256 fee, uint256 quoteIn, uint256 tokensOut) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));
            assertEq(quote, USDC);
            assertEq(team_, childTeam);
            assertEq(fee, FEE);
            assertEq(quoteIn, 150e6, "quoteIn is not the buy");
            assertEq(tokensOut, out, "tokensOut is not what the launcher received");
            found = true;
        }
        assertTrue(found, "no ChildLaunched");
    }

    function test_GovernanceVaultMustHaveCode() public {
        vm.expectRevert(bytes("governance vault missing"));
        new CubitForgeV2(hook, FEE, makeAddr("no code"), _quotes(), _values());
    }

    // ================================================================== v1 -> v2

    /// @dev After `setForge(v2)`, the v1 Forge launches nothing more, but a child it launched keeps
    ///      trading and keeps delivering what its crossed walls absorb to the v1 Forge's governance vault.
    function test_V1ChildKeepsDeliveringAfterV2() public {
        // Start over from a v1 launchpad on the same governance vault.
        CubitForge v1 = new CubitForge(hook, FEE, address(governanceVault));
        vm.startPrank(team);
        registry.setForge(address(v1));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
        (address childToken, address childHook) = _launchV1(v1, alice);

        vm.startPrank(team);
        registry.setForge(address(forgeV2));
        registry.activate(FORGE_BIT);
        vm.stopPrank();

        vm.deal(bob, FEE);
        vm.prank(bob);
        vm.expectRevert(bytes("Forge inactive"));
        v1.launch{value: FEE}("Z", "Z", bob, bytes32(0), bytes32(0), type(CubitHook).creationCode);

        CubitHook ch = CubitHook(payable(childHook));
        assertEq(ch.absorbedTokenSink(), address(governanceVault), "the v1 child lost its sink");
        Child memory c = Child(CubitForgeToken(childToken), CubitQuoteHook(address(0)), ch.poolKey(), ETH);
        uint256 got = _buyChild(c, bob, 1 ether);
        _sellChild(c, bob, got / 10);
        _sellChild(c, bob, CubitForgeToken(childToken).balanceOf(bob));
        uint256 absorbed = ch.pendingAbsorbedTokens();
        assertGt(absorbed, 0);
        ch.deliverAbsorbed();
        assertEq(governanceVault.held(childToken), absorbed, "the v1 child no longer feeds the governance vault");
    }

    function _launchV1(CubitForge v1, address launcher) internal returns (address, address) {
        bytes32 tokenSalt = bytes32(uint256(7));
        address predicted = vm.computeCreate2Address(
            keccak256(abi.encode(launcher, tokenSalt)),
            keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode("V1", "V1"))),
            address(v1)
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CubitHook).creationCode, abi.encode(manager, predicted, launcher, hook.LAUNCH_ETH()))
        );
        bytes32 hookSalt;
        for (uint256 i; i < 1_000_000; i++) {
            address candidate = vm.computeCreate2Address(keccak256(abi.encode(launcher, bytes32(i))), initCodeHash, address(v1));
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == FLAGS && candidate.code.length == 0) {
                hookSalt = bytes32(i);
                break;
            }
        }
        vm.deal(launcher, launcher.balance + FEE);
        vm.prank(launcher);
        return v1.launch{value: FEE}("V1", "V1", launcher, tokenSalt, hookSalt, type(CubitHook).creationCode);
    }
}

