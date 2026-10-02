// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TokenFirstBase} from "./utils/TokenFirstBase.sol";
import {CubitForgeV3} from "../../src/periphery/CubitForgeV3.sol";
import {CubitForgeToken} from "../../src/periphery/CubitForge.sol";
import {CubitQuoteHook} from "../../src/quote/CubitQuoteHook.sol";
import {CubitTokenFirstHook} from "../../src/quote/CubitTokenFirstHook.sol";
import {ICubitQuoteHook} from "../../src/quote/ICubitQuoteHook.sol";
import {QuoteBandLib} from "../../src/quote/QuoteBandLib.sol";
import {TokenFirstBandLib} from "../../src/quote/TokenFirstBandLib.sol";
import {QuoteTaxes} from "../../src/quote/QuoteTaxes.sol";

/// @notice Launchpad v3 (TOKEN/QUOTE for every ERC-20 pair): launches, orientation, taxes, walls, deliveries, team
///         payments, refusals, and a differential test against the reviewed launchpad v2 child (QUOTE/TOKEN) under the
///         same trades.
contract TokenFirstLaunchpadTest is TokenFirstBase {
    // ------------------------------------------------------------------ launches and orientation

    function test_LaunchEveryQuoteInItsOrientation() public {
        address[] memory q = _quotes();
        for (uint256 i; i < q.length; i++) {
            (Kid memory k,) = _launchV3(alice, q[i], 0);
            assertTrue(k.hook.initialized(), "not initialized");
            if (q[i] == ETH) {
                assertEq(Currency.unwrap(k.key.currency0), ETH, "ETH is currency0");
                assertEq(Currency.unwrap(k.key.currency1), address(k.token));
            } else {
                assertEq(Currency.unwrap(k.key.currency0), address(k.token), "token is not currency0");
                assertEq(Currency.unwrap(k.key.currency1), q[i], "quote is not currency1");
                assertTrue(CubitTokenFirstHook(address(k.hook)).TOKEN_IS_CURRENCY0());
                assertLt(uint160(address(k.token)), uint160(q[i]), "token above its quote");
                (int24 lower, int24 upper, uint128 liquidity) = k.hook.band();
                assertGt(liquidity, 0, "empty band");
                assertGt(lower, _kidTick(k), "band not above the price");
                assertEq(upper, TickMath.maxUsableTick(10), "band does not reach the top");
                // The launch price is the launch value over the supply, quote per token, to 1e-15.
                uint256 price = TokenFirstBandLib.priceAtSqrt(k.hook.INITIAL_SQRT_PRICE());
                uint256 expected = forgeV3.launchValue(q[i]) * 1e36 / 21_000_000e18;
                assertApproxEqRel(price, expected, 1e3, "launch price");
            }
            assertEq(k.token.balanceOf(address(manager)) + k.token.totalBurned(), k.token.TOTAL_SUPPLY(), "supply not in band");
            assertEq(k.hook.absorbedTokenSink(), address(governanceVault));
            _assertKidBooks(k);
        }
        assertEq(forgeV3.launches(), q.length);
    }

    function test_TokenAboveTheQuoteIsRefused() public {
        (CubitForgeV3.LaunchParams memory p,,) = _v3Params(alice, TSLAON, 0, "Kid");
        // A salt giving a token address above TSLAon (TSLAon is 0xf6b1…: few do, so search).
        bytes32 codeHash = keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode("Kid", "KID")));
        for (uint256 i; i < 10_000; i++) {
            address predicted = _create2(keccak256(abi.encode(alice, bytes32(i))), codeHash, address(forgeV3));
            if (uint160(predicted) > uint160(TSLAON)) { p.tokenSalt = bytes32(i); break; }
        }
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("token sorts above quote"));
        forgeV3.launch{value: FEE}(p, type(CubitTokenFirstHook).creationCode);
    }

    function test_EachQuoteNeedsItsTemplate() public {
        (CubitForgeV3.LaunchParams memory p,,) = _v3Params(alice, USDC, 0, "Kid");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("template mismatch"));
        forgeV3.launch{value: FEE}(p, type(CubitQuoteHook).creationCode);
        (CubitForgeV3.LaunchParams memory e,,) = _v3Params(alice, ETH, 0, "Kid");
        vm.prank(alice);
        vm.expectRevert(bytes("template mismatch"));
        forgeV3.launch{value: FEE}(e, type(CubitTokenFirstHook).creationCode);
        assertEq(forgeV3.hookCreationCodeHashFor(ETH), keccak256(type(CubitQuoteHook).creationCode));
        assertEq(forgeV3.hookCreationCodeHashFor(USDC), keccak256(type(CubitTokenFirstHook).creationCode));
    }

    function test_ThePairCannotBeTheTeam() public {
        (CubitForgeV3.LaunchParams memory p,,) = _v3Params(alice, USDC, 0, "Kid");
        p.team = USDC;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("invalid team"));
        forgeV3.launch{value: FEE}(p, type(CubitTokenFirstHook).creationCode);
    }

    function test_ConstructorRefusesBadTemplates() public {
        address[] memory q = _quotes();
        uint256[] memory v = _values();
        vm.expectRevert(bytes("invalid templates"));
        new CubitForgeV3(hook, FEE, address(governanceVault), q, v, bytes32(0), keccak256("x"));
        vm.expectRevert(bytes("invalid templates"));
        new CubitForgeV3(hook, FEE, address(governanceVault), q, v, keccak256("x"), keccak256("x"));
    }

    function test_HookRefusesTheWrongOrder() public {
        // A token-first hook whose token sorts above its quote cannot be built.
        vm.expectRevert(CubitTokenFirstHook.TokenNotCurrency0.selector);
        new CubitTokenFirstHook(manager, token, childTeam, Currency.wrap(address(1)), 15_000e6, taxes);
    }

    // ------------------------------------------------------------------ the launcher's buy and trading

    function test_LaunchBuyEveryQuote() public {
        address[] memory q = _quotes();
        uint256[] memory v = _values();
        for (uint256 i; i < q.length; i++) {
            uint256 buyAmount = v[i] / 100;
            uint256 before = _balance(q[i], alice);
            (Kid memory k, uint256 out) = _launchV3(alice, q[i], buyAmount);
            assertGt(out, 0, "no tokens");
            assertEq(k.token.balanceOf(alice), out, "tokens not delivered");
            assertEq(k.hook.teamAccrued(), (buyAmount * 300 + 9_999) / 10_000, "buy tax");
            if (q[i] != ETH) assertEq(before + buyAmount - _balance(q[i], alice), buyAmount, "quote not pulled");
            if (k.tokenFirst) assertGt(_kidTick(k), TickMath.getTickAtSqrtPrice(k.hook.INITIAL_SQRT_PRICE()), "a buy must raise the tick");
            _assertKidBooks(k);
        }
    }

    function test_TradingCycleEveryErc20Quote() public {
        address[] memory q = _quotes();
        uint256[] memory v = _values();
        for (uint256 i = 1; i < q.length; i++) {
            (Kid memory k,) = _launchV3Named(alice, q[i], 0, string.concat("Kid", vm.toString(i)));
            uint256 got = _buyKid(k, bob, v[i] / 5);
            assertGt(got, 0);
            uint256 teamAfterBuy = k.hook.teamAccrued();
            _sellKid(k, bob, got / 10);
            assertGt(k.hook.activeWallCount(), 0, "no wall after a sale");
            (bool exists, int24 nearest) = k.hook.nearestWallTick();
            assertTrue(exists);
            assertLe(nearest + 10, _kidTick(k), "the wall is not under the price");
            _assertKidBooks(k);
            _sellKid(k, bob, k.token.balanceOf(bob));
            _assertNoCrossedKidWall(k);
            assertGt(k.hook.pendingAbsorbedTokens(), 0, "no wall crossed");
            uint256 locked0 = governanceVault.held(address(k.token));
            uint256 absorbed = k.hook.pendingAbsorbedTokens();
            k.hook.deliverAbsorbed();
            assertEq(governanceVault.held(address(k.token)) - locked0, absorbed, "absorbed tokens not locked");
            uint256 accrued = k.hook.teamAccrued();
            assertGt(accrued, teamAfterBuy, "sales paid no team share");
            uint256 teamBefore = _balance(q[i], childTeam);
            k.hook.claimTeam();
            assertEq(_balance(q[i], childTeam) - teamBefore, accrued, "team not paid in the quote");
            _assertKidBooks(k);
        }
    }

    function test_ExactOutputModesAreTaxed() public {
        (Kid memory k,) = _launchV3(alice, USDC, 0);
        uint256 paid = _buyKidExactOut(k, bob, 1_000_000e18, 100_000e6);
        assertEq(k.token.balanceOf(bob), 1_000_000e18, "exact output not delivered");
        // Buy tax: tax / (paid) = 3%, rounded up.
        assertApproxEqAbs(k.hook.teamAccrued(), paid * 300 / 10_000, 1, "exact-output buy tax");
        uint256 team0 = k.hook.teamAccrued();
        uint256 tokensIn = _sellKidExactOut(k, bob, 100e6);
        assertGt(tokensIn, 0);
        // Sale tax: gross = out + tax, tax = 15% of gross: team 3/15, walls 12/15.
        uint256 tax = (k.hook.teamAccrued() - team0) * 5;
        assertApproxEqAbs(tax * 10_000 / (100e6 + tax), 1_500, 1, "exact-output sale tax");
        _assertKidBooks(k);
    }

    function test_WallOnePercentUnderBelowLaunch() public {
        (Kid memory k,) = _launchV3(alice, USDC, 0);
        uint256 got = _buyKid(k, bob, 3_000e6);
        deal(address(k.token), bob, got + 100_000e18);
        int24 launchTick = TickMath.getTickAtSqrtPrice(k.hook.INITIAL_SQRT_PRICE());
        uint160 limit = TickMath.getSqrtPriceAtTick(launchTick - 2_000);
        int256 amount = -int256(k.token.balanceOf(bob));
        vm.startPrank(bob);
        k.token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            k.key,
            SwapParams({zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        uint256 current = TokenFirstBandLib.priceAtSqrt(_kidSqrtP(k));
        assertLt(current, TokenFirstBandLib.priceAtSqrt(k.hook.INITIAL_SQRT_PRICE()), "not under the launch price");
        (bool exists, int24 lower) = k.hook.nearestWallTick();
        assertTrue(exists, "no wall under launch");
        // The wall's highest price is its upper tick's.
        uint256 wallTop = TokenFirstBandLib.priceAtSqrt(TickMath.getSqrtPriceAtTick(lower + 10));
        uint256 target = current * 9_900 / 10_000;
        assertLe(wallTop, target, "the wall is closer than 1%");
        assertGe(wallTop, target * 9_980 / 10_000, "the wall is more than two spacings under 1%");
    }

    function test_NobodyElseAddsLiquidity() public {
        (Kid memory k,) = _launchV3(alice, USDC, 0);
        uint160 sqrtPrice = k.hook.INITIAL_SQRT_PRICE();
        vm.expectRevert();
        manager.initialize(k.key, sqrtPrice);
        ModifyLiquidityParams memory params;
        vm.prank(address(manager));
        vm.expectRevert(ICubitQuoteHook.ExternalLiquidityForbidden.selector);
        CubitTokenFirstHook(address(k.hook)).beforeAddLiquidity(alice, k.key, params, "");
    }

    function test_ExtremeTrades() public {
        (Kid memory k,) = _launchV3(alice, USDC, 0);
        uint256 got = _buyKid(k, bob, 1e30);
        assertGt(got, 20_000_000e18, "the whale did not take nearly the whole band");
        _sellKid(k, bob, got / 3);
        _sellKid(k, bob, k.token.balanceOf(bob));
        _assertKidBooks(k);
        _assertNoCrossedKidWall(k);
    }

    function test_LaunchBoundsKeepTheWholeBand() public {
        // The cheapest and the dearest launch value the Forge accepts for an 18-decimal quote.
        uint256[2] memory values = [uint256(1e8), 1e36];
        for (uint256 j; j < 2; j++) {
            if (!forgeV3.validLaunchValueFor(TSLAON, values[j])) continue;
            address[] memory q = new address[](1);
            uint256[] memory v = new uint256[](1);
            (q[0], v[0]) = (TSLAON, values[j]);
            forgeV3 = new CubitForgeV3(hook, FEE, address(governanceVault), q, v,
                keccak256(type(CubitQuoteHook).creationCode), keccak256(type(CubitTokenFirstHook).creationCode));
            _registerV3();
            (Kid memory k,) = _launchV3Named(alice, TSLAON, 0, string.concat("Bound", vm.toString(j)));
            assertGe(k.token.balanceOf(address(manager)), 16_800_000e18, "the band did not take the supply");
            _assertKidBooks(k);
        }
    }

    function testFuzz_RandomTrading(uint256 seed) public {
        (Kid memory k,) = _launchV3(alice, WBTC, 0);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address a = who[seed % 2];
            if (seed % 3 == 0 && k.token.balanceOf(a) > 0) {
                _sellKid(k, a, k.token.balanceOf(a) * (1 + (seed >> 8) % 100) / 100);
                _assertNoCrossedKidWall(k);
            } else {
                _buyKid(k, a, 1 + (seed >> 16) % 0.05e8);
            }
            _assertKidBooks(k);
        }
        k.hook.deliverAbsorbed();
        k.hook.claimTeam();
        _assertKidBooks(k);
    }

    // ------------------------------------------------------------------ differential: v2 (QUOTE/TOKEN) vs v3 (TOKEN/QUOTE)

    /// @dev The same trades on a v2 child (quote first) and a v3 child (token first) of the same quote and launch value
    ///      give the same tokens, quote, taxes, absorbed tokens and walls, to rounding: the v3 hook is the v2 mechanism
    ///      in the mirrored orientation, nothing else.
    function test_SameTradesSameResultsAsTheV2() public {
        // v2 child first, while the Forge v2 is registered.
        vm.startPrank(team);
        registry.setForge(address(forgeV2));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
        (Child memory c,) = _launch(alice, USDC, 0);
        _registerV3();
        (Kid memory k,) = _launchV3(alice, USDC, 0);
        assertEq(forgeV2.launchValue(USDC), forgeV3.launchValue(USDC));

        uint256[3] memory buys = [uint256(3_000e6), 1_000e6, 7_500e6];
        for (uint256 i; i < 3; i++) {
            uint256 a = _buyChild(c, bob, buys[i]);
            uint256 b = _buyKid(k, carol, buys[i]);
            assertApproxEqRel(a, b, 1e12, "tokens bought differ"); // 1e-6
        }
        assertEq(c.hook.teamAccrued(), k.hook.teamAccrued(), "buy taxes differ");
        uint256[3] memory sells = [uint256(2), 3, 1]; // fractions of the remaining holding: 1/2, 1/3, all
        for (uint256 i; i < 3; i++) {
            uint256 heldC = c.token.balanceOf(bob);
            uint256 heldK = k.token.balanceOf(carol);
            uint256 inC = sells[i] == 1 ? heldC : heldC / sells[i];
            uint256 inK = sells[i] == 1 ? heldK : heldK / sells[i];
            uint256 outC = _sellChild(c, bob, inC);
            uint256 outK = _sellKid(k, carol, inK);
            assertApproxEqRel(outC, outK, 1e12, "quote out differs");
            assertEq(c.hook.activeWallCount(), k.hook.activeWallCount(), "wall counts differ");
        }
        assertApproxEqRel(c.hook.teamAccrued(), k.hook.teamAccrued(), 1e12, "team shares differ");
        assertApproxEqRel(c.hook.pendingAbsorbedTokens(), k.hook.pendingAbsorbedTokens(), 1e12, "absorbed differ");
        assertEq(c.hook.wallCount(), k.hook.wallCount(), "walls ever placed differ");
        // Every wall at the mirrored price: v2 wall [L, L+10] (price at L is its highest) vs v3 wall [l, l+10] (price at
        // l+10 its highest): the same price to one spacing.
        for (uint256 id; id < c.hook.wallCount(); id++) {
            (int24 lc,,, uint256 fundedC) = c.hook.walls(id);
            (int24 lk,,, uint256 fundedK) = k.hook.walls(id);
            assertLe(_abs(int256(lc) + int256(lk) + 10), 10, "wall prices differ by more than one spacing");
            assertApproxEqRel(fundedC, fundedK, 1e12, "wall funding differs");
        }
        _assertChildBooks(c);
        _assertKidBooks(k);
    }

    address internal carol = makeAddr("carol");

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
