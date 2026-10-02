// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {assertInvariant} from "../../utils/InvariantAssertions.sol";
import {MockQuote} from "../../../script/mocks/TestQuotes.sol";
import {QuoteSwapper} from "../../../script/mocks/TestSwapper.sol";
import {CubitForgeToken} from "../../../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../../../src/periphery/CubitForgeV2.sol";
import {CubitQuoteHook} from "../../../src/quote/CubitQuoteHook.sol";
import {QuoteBandLib} from "../../../src/quote/QuoteBandLib.sol";
import {TokenFirstBandLib} from "../../../src/quote/TokenFirstBandLib.sol";

/// @notice Random trades, deliveries, team claims, donations and two-hop routes on several launchpad v2 children that
///         share a PoolManager (ETH, two USDC children, WBTC). After every action it checks the invariants:
///         exact books net of donations, no raw holdings but donations, fixed
///         supply, no crossed wall left, monotone team entitlement, wall-index consistency, a permanent band, no wall
///         funds piling up, an empty Forge, and isolation: a child that does not take part does not move.
contract QuoteHandler is CommonBase, StdCheats, StdUtils {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    CubitForgeV2 public immutable forge;
    QuoteSwapper public immutable swapper;
    PoolSwapTest public immutable raw;
    PoolClaimsTest public immutable claims;

    CubitQuoteHook[] public hooks;
    address[] internal actors;
    mapping(address hook => uint256) public donatedQuoteClaims;
    mapping(address hook => uint256) public donatedRawQuote;
    mapping(address hook => uint256) public donatedRawTokens;
    mapping(address hook => uint256) internal lastTeamTotal;
    mapping(address hook => uint128) internal bandLiquidity;
    /// @notice Launchpad v3 children whose token is currency0 (CubitTokenFirstHook): their buys are oneForZero and their
    ///         walls stand under the price. Marked by the test's set-up, never by the campaign (not a target selector).
    mapping(address hook => bool) public tokenFirst;

    uint256 public trades;
    uint256 public refusals;
    uint256 public wallsCrossed;
    uint256 public twoHops;
    uint256 public calls;

    constructor(IPoolManager manager_, CubitForgeV2 forge_, CubitQuoteHook[] memory hooks_) {
        manager = manager_;
        forge = forge_;
        swapper = new QuoteSwapper(manager_);
        raw = new PoolSwapTest(manager_);
        claims = new PoolClaimsTest(manager_);
        for (uint256 i; i < hooks_.length; i++) {
            hooks.push(hooks_[i]);
            (,, bandLiquidity[address(hooks_[i])]) = hooks_[i].band();
        }
        actors.push(makeAddr("inv-alice"));
        actors.push(makeAddr("inv-bob"));
        actors.push(makeAddr("inv-carol"));
    }

    /// @dev The child the last successful sale traded on (reset each step): right after a sale, its wall funds must be
    ///      placed, whatever walls already stand.
    CubitQuoteHook internal soldOn;

    modifier step() {
        calls++;
        soldOn = CubitQuoteHook(address(0));
        _;
        _afterStep();
    }

    function markTokenFirst(address h) external {
        tokenFirst[h] = true;
    }

    function hookCount() external view returns (uint256) {
        return hooks.length;
    }

    // ------------------------------------------------------------------ helpers

    function _hook(uint256 seed) internal view returns (CubitQuoteHook) {
        return hooks[seed % hooks.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _quote(CubitQuoteHook h) internal view returns (address) {
        return Currency.unwrap(h.quote());
    }

    function _fdv(CubitQuoteHook h) internal view returns (uint256) {
        return h.LAUNCH_QUOTE();
    }

    function _fund(address quote, address who, uint256 amount) internal {
        if (quote == address(0)) vm.deal(who, who.balance + amount);
        else MockQuote(quote).mint(who, amount);
    }

    function _approveAll(CubitQuoteHook h, address who, address spender) internal {
        vm.startPrank(who);
        if (_quote(h) != address(0)) IERC20(_quote(h)).approve(spender, type(uint256).max);
        IERC20(address(h.token())).approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function _swap(CubitQuoteHook h, address who, bool zeroForOne, int256 amount, uint256 value) internal returns (bool ok) {
        _approveAll(h, who, address(swapper));
        PoolKey memory key = h.poolKey(); // before the prank: a call in the arguments would consume it
        vm.prank(who);
        try swapper.swap{value: value}(key, zeroForOne, amount) {
            trades++;
            ok = true;
        } catch {
            refusals++;
        }
    }

    // ------------------------------------------------------------------ actions

    function buyExactIn(uint256 hookSeed, uint256 actorSeed, uint256 amount) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address who = _actor(actorSeed);
        amount = bound(amount, _fdv(h) / 1_000_000 + 2, _fdv(h) / 3);
        _fund(_quote(h), who, amount);
        _swap(h, who, !tokenFirst[address(h)], -int256(amount), _quote(h) == address(0) ? amount : 0);
    }

    function buyExactOut(uint256 hookSeed, uint256 actorSeed, uint256 tokens) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address who = _actor(actorSeed);
        tokens = bound(tokens, 1e18, 2_000_000e18);
        uint256 budget = _fdv(h); // far more than 2M tokens can cost near launch; the swapper refunds ETH
        _fund(_quote(h), who, budget);
        _swap(h, who, !tokenFirst[address(h)], int256(tokens), _quote(h) == address(0) ? budget : 0);
    }

    function sellExactIn(uint256 hookSeed, uint256 actorSeed, uint256 bps) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address who = _actor(actorSeed);
        uint256 held = h.token().balanceOf(who);
        if (held == 0) return;
        uint256 amount = held * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        uint256 walls0 = h.activeWallCount();
        if (_swap(h, who, tokenFirst[address(h)], -int256(amount), 0)) soldOn = h;
        if (h.activeWallCount() < walls0) wallsCrossed += walls0 - h.activeWallCount();
    }

    function sellExactOut(uint256 hookSeed, uint256 actorSeed, uint256 quoteOut) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address who = _actor(actorSeed);
        if (h.token().balanceOf(who) == 0) return;
        quoteOut = bound(quoteOut, 2, _fdv(h) / 50);
        if (_swap(h, who, tokenFirst[address(h)], int256(quoteOut), 0)) soldOn = h;
    }

    /// @dev A sale stopped by a price limit a random number of ticks up (partial fills allowed, PoolSwapTest).
    function rawSell(uint256 hookSeed, uint256 actorSeed, uint256 bps, uint256 ticks) external step {
        CubitQuoteHook h = _hook(hookSeed);
        if (_quote(h) != address(0) && _quote(h).code.length == 0) return;
        address who = _actor(actorSeed);
        uint256 held = h.token().balanceOf(who);
        if (held == 0) return;
        uint256 amount = held * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        (, int24 tick,,) = manager.getSlot0(h.poolId());
        // A sale moves the tick up for a quote-first child, down for a token-first one.
        bool tf = tokenFirst[address(h)];
        int24 step_ = int24(int256(bound(ticks, 1, 50_000)));
        int24 limitTick = tf ? tick - step_ : tick + step_;
        if (limitTick >= TickMath.MAX_TICK || limitTick <= TickMath.MIN_TICK) return;
        _approveAll(h, who, address(raw));
        PoolKey memory key = h.poolKey();
        vm.prank(who);
        try raw.swap(
            key,
            SwapParams({zeroForOne: tf, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            trades++;
            soldOn = h;
        } catch {
            refusals++;
        }
    }

    /// @dev Child A -> quote -> child B in one unlock, for two children that share a quote. The third child must not move.
    function twoHop(uint256 aSeed, uint256 bSeed, uint256 actorSeed, uint256 bps) external step {
        CubitQuoteHook a = _hook(aSeed);
        CubitQuoteHook b = _hook(bSeed);
        // The swapper's two-hop route assumes the quote is currency0 (launchpad v2 children).
        if (address(a) == address(b) || _quote(a) != _quote(b) || tokenFirst[address(a)] || tokenFirst[address(b)]) return;
        address who = _actor(actorSeed);
        uint256 held = a.token().balanceOf(who);
        uint256 amount = held * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        uint160[] memory before = _otherPrices(a, b);
        _approveAll(a, who, address(swapper));
        (PoolKey memory keyA, PoolKey memory keyB) = (a.poolKey(), b.poolKey());
        vm.prank(who);
        try swapper.swapThrough(keyA, keyB, amount) {
            twoHops++;
        } catch {
            refusals++;
        }
        _assertOthersStill(a, b, before);
    }

    function deliverAbsorbed(uint256 hookSeed) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address vault = forge.governanceVault();
        uint256 pending = h.pendingAbsorbedTokens();
        uint256 before = h.token().balanceOf(vault);
        h.deliverAbsorbed();
        assertInvariant(h.token().balanceOf(vault) - before == pending, "the delivery did not reach the governance vault");
    }

    function claimTeam(uint256 hookSeed) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address team = h.TEAM_ADDRESS();
        address quote = _quote(h);
        uint256 due = h.teamAccrued();
        uint256 before = quote == address(0) ? team.balance : IERC20(quote).balanceOf(team);
        h.claimTeam();
        uint256 afterBalance = quote == address(0) ? team.balance : IERC20(quote).balanceOf(team);
        assertInvariant(afterBalance - before == due, "the team was not paid exactly its due");
    }

    /// @dev ERC-6909 claims given to a hook: they must never be spent or counted by the protocol.
    function donateClaims(uint256 hookSeed, uint256 amount) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address quote = _quote(h);
        if (quote == address(0)) return;
        address who = actors[0];
        amount = bound(amount, 1, _fdv(h) / 100);
        _fund(quote, who, amount);
        vm.startPrank(who);
        IERC20(quote).approve(address(claims), amount);
        claims.deposit(h.quote(), who, amount);
        manager.transfer(address(h), uint256(uint160(quote)), amount);
        vm.stopPrank();
        donatedQuoteClaims[address(h)] += amount;
    }

    /// @dev Raw quote or raw child tokens sent to a hook.
    function donateRaw(uint256 hookSeed, uint256 actorSeed, uint256 amount, bool tokens) external step {
        CubitQuoteHook h = _hook(hookSeed);
        address who = _actor(actorSeed);
        if (tokens) {
            uint256 held = h.token().balanceOf(who);
            if (held == 0) return;
            amount = bound(amount, 1, held);
            IERC20 token = IERC20(address(h.token())); // before the prank
            vm.prank(who);
            token.transfer(address(h), amount);
            donatedRawTokens[address(h)] += amount;
        } else {
            amount = bound(amount, 1, _fdv(h) / 100);
            if (_quote(h) == address(0)) vm.deal(address(h), address(h).balance + amount);
            else MockQuote(_quote(h)).mint(address(h), amount);
            donatedRawQuote[address(h)] += amount;
        }
    }

    // ------------------------------------------------------------------ checks

    function _otherPrices(CubitQuoteHook a, CubitQuoteHook b) internal view returns (uint160[] memory p) {
        p = new uint160[](hooks.length);
        for (uint256 i; i < hooks.length; i++) {
            if (hooks[i] == a || hooks[i] == b) continue;
            (p[i],,,) = manager.getSlot0(hooks[i].poolId());
        }
    }

    function _assertOthersStill(CubitQuoteHook a, CubitQuoteHook b, uint160[] memory before) internal view {
        for (uint256 i; i < hooks.length; i++) {
            if (hooks[i] == a || hooks[i] == b) continue;
            (uint160 p,,,) = manager.getSlot0(hooks[i].poolId());
            assertInvariant(p == before[i], "a child outside the route moved");
        }
    }

    function _afterStep() internal {
        for (uint256 i; i < hooks.length; i++) {
            CubitQuoteHook h = hooks[i];
            uint256 total = h.teamAccrued() + h.teamPaidCumulative();
            assertInvariant(total >= lastTeamTotal[address(h)], "the team entitlement decreased");
            lastTeamTotal[address(h)] = total;
            _assertNoWallFundsPile(h);
        }
        checkAll();
    }

    /// @dev After a sale, pending wall funds must have been placed: only dust waits, or funds at the top of the tick
    ///      range, or funds for a target wall already at the liquidity cap.
    function _assertNoWallFundsPile(CubitQuoteHook h) internal view {
        uint256 pending = h.pendingFloorQuote();
        if (pending <= 10) return;
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(h.poolId());
        int24 spacing = h.TICK_SPACING();
        int24 target;
        if (tokenFirst[address(h)]) {
            int24 upper = TokenFirstBandLib.retracementWallUpper(h.INITIAL_SQRT_PRICE(), sqrtP, spacing);
            if (upper > tick) upper = TokenFirstBandLib.underMarketWallUpper(sqrtP, spacing);
            if (upper > tick) return; // no room under the price at the bottom of the range
            target = upper - spacing;
        } else {
            target = QuoteBandLib.retracementWallTarget(h.INITIAL_SQRT_PRICE(), sqrtP, spacing);
            if (tick >= target) target = QuoteBandLib.underMarketWallTarget(sqrtP, spacing);
            if (tick >= target) return; // no room under the price at the top of the range
        }
        uint256 active = h.activeWallCount();
        for (uint256 i; i < active; i++) {
            (int24 lower, uint128 liquidity,,) = h.walls(h.activeWallId(i));
            if (lower == target && liquidity == h.MAX_LIQUIDITY_PER_TICK()) return;
        }
        // Right after a sale on this child, nothing else may wait. Otherwise (a step that did not sell here) funds can
        // only wait with a wall standing: only sales place walls.
        if (h == soldOn) assertInvariant(false, "a sale left its wall funds unplaced");
        assertInvariant(h.activeWallCount() != 0 || pending <= 10, "wall funds piled up with no wall at all");
    }

    function checkAll() public view {
        for (uint256 i; i < hooks.length; i++) checkChild(hooks[i]);
        assertInvariant(address(forge).balance == 0, "the Forge holds ETH");
    }

    function checkChild(CubitQuoteHook h) public view {
        address quote = _quote(h);
        CubitForgeToken token = CubitForgeToken(address(h.token()));
        // Claims are the books plus exactly what was donated.
        assertInvariant(
            manager.balanceOf(address(h), uint256(uint160(quote)))
                == h.pendingFloorQuote() + h.teamAccrued() + h.wallIdleQuote() + donatedQuoteClaims[address(h)],
            "quote claims differ from the books plus donations"
        );
        assertInvariant(
            manager.balanceOf(address(h), uint256(uint160(address(token)))) == h.pendingAbsorbedTokens(),
            "token claims differ from the absorbed queue"
        );
        // Raw holdings are donations only.
        uint256 rawQuote = quote == address(0) ? address(h).balance : IERC20(quote).balanceOf(address(h));
        assertInvariant(rawQuote == donatedRawQuote[address(h)], "the hook holds raw quote beyond donations");
        assertInvariant(token.balanceOf(address(h)) == donatedRawTokens[address(h)], "the hook holds raw tokens beyond donations");
        // Fixed supply.
        assertInvariant(token.totalSupply() + token.totalBurned() == token.TOTAL_SUPPLY(), "supply accounting");
        // No fully crossed wall remains.
        (bool exists, int24 nearest) = h.nearestWallTick();
        (, int24 tick,,) = manager.getSlot0(h.poolId());
        bool tf = tokenFirst[address(h)];
        assertInvariant(!exists || (tf ? tick >= nearest : tick < nearest + h.TICK_SPACING()), "a fully crossed wall remains");
        // The nearest wall is the lowest active one, the highest for a token-first child.
        uint256 n = h.activeWallCount();
        int24 extreme = tf ? type(int24).min : type(int24).max;
        for (uint256 i; i < n; i++) {
            (int24 lower, uint128 liquidity,,) = h.walls(h.activeWallId(i));
            assertInvariant(liquidity != 0, "an active wall holds no liquidity");
            if (tf ? lower > extreme : lower < extreme) extreme = lower;
        }
        assertInvariant(exists == (n != 0) && (n == 0 || nearest == extreme), "nearest wall index");
        uint256 idle;
        for (uint256 id; id < h.wallCount(); id++) {
            (,, uint256 wallIdle,) = h.walls(id);
            idle += wallIdle;
        }
        assertInvariant(idle == h.wallIdleQuote(), "per-wall idle quote does not sum to the book");
        // The band never changes after the bootstrap.
        (int24 bLower, int24 bUpper, uint128 bLiquidity) = h.band();
        assertInvariant(bLiquidity == bandLiquidity[address(h)], "the band's book changed");
        (uint128 positionLiquidity,,) =
            manager.getPositionInfo(h.poolId(), address(h), bLower, bUpper, h.BAND_SALT());
        assertInvariant(positionLiquidity == bLiquidity, "the band position changed");
    }
}
