// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {QuoteBase} from "./QuoteBase.sol";
import {MockQuote} from "./QuoteMocks.sol";
import {CubitForgeToken} from "../../../src/periphery/CubitForge.sol";
import {CubitForgeV3} from "../../../src/periphery/CubitForgeV3.sol";
import {CubitQuoteHook} from "../../../src/quote/CubitQuoteHook.sol";
import {CubitTokenFirstHook} from "../../../src/quote/CubitTokenFirstHook.sol";
import {ICubitQuoteHook} from "../../../src/quote/ICubitQuoteHook.sol";

/// @notice Launchpad v3 set-up: the v2 set-up (quotes, governance vault, swapper, the Forge v2 for differential tests),
///         plus a CubitForgeV3 registered in its place. An ETH child runs CubitQuoteHook (ETH/TOKEN), an ERC-20 child
///         CubitTokenFirstHook (TOKEN/QUOTE).
abstract contract TokenFirstBase is QuoteBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    CubitForgeV3 internal forgeV3;

    struct Kid {
        CubitForgeToken token;
        ICubitQuoteHook hook;
        PoolKey key;
        address quote;
        bool tokenFirst;
    }

    function setUp() public virtual override {
        super.setUp();
        forgeV3 = new CubitForgeV3(hook, FEE, address(governanceVault), _quotes(), _values(),
            keccak256(type(CubitQuoteHook).creationCode), keccak256(type(CubitTokenFirstHook).creationCode));
        _registerV3();
    }

    function _registerV3() internal {
        vm.startPrank(team);
        registry.setForge(address(forgeV3));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
    }

    function _code(address quote) internal pure returns (bytes memory) {
        return quote == ETH ? type(CubitQuoteHook).creationCode : type(CubitTokenFirstHook).creationCode;
    }

    /// @dev The first token salt giving an address the Forge v3 accepts: above ETH, under an ERC-20 quote.
    function _v3TokenSalt(address launcher, address quote, string memory name_, string memory symbol_)
        internal view returns (bytes32 salt, address predicted)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode(name_, symbol_)));
        for (uint256 i; i < 100_000; i++) {
            salt = bytes32(i);
            predicted = _create2(keccak256(abi.encode(launcher, salt)), codeHash, address(forgeV3));
            bool ok = quote == ETH ? true : uint160(predicted) < uint160(quote);
            if (ok && predicted.code.length == 0) return (salt, predicted);
        }
        revert("no token salt");
    }

    function _v3HookSalt(address launcher, address token_, address quote, address team_)
        internal view returns (bytes32, address)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            _code(quote), abi.encode(manager, token_, team_, quote, forgeV3.launchValue(quote), taxes)
        ));
        for (uint256 i; i < 1_000_000; i++) {
            address candidate = _create2(keccak256(abi.encode(launcher, bytes32(i))), initCodeHash, address(forgeV3));
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == FLAGS && candidate.code.length == 0) {
                return (bytes32(i), candidate);
            }
        }
        revert("no hook salt");
    }

    function _v3Params(address launcher, address quote, uint256 buyAmount, string memory name_)
        internal view returns (CubitForgeV3.LaunchParams memory p, address token_, address hook_)
    {
        (bytes32 tokenSalt, address predicted) = _v3TokenSalt(launcher, quote, name_, "KID");
        (bytes32 hookSalt, address predictedHook) = _v3HookSalt(launcher, predicted, quote, childTeam);
        p = CubitForgeV3.LaunchParams({
            name: name_, symbol: "KID", team: childTeam, quote: quote,
            tokenSalt: tokenSalt, hookSalt: hookSalt, buyAmount: buyAmount, taxes: taxes
        });
        (token_, hook_) = (predicted, predictedHook);
    }

    function _launchV3(address launcher, address quote, uint256 buyAmount) internal returns (Kid memory k, uint256 out) {
        return _launchV3Named(launcher, quote, buyAmount, "Kid");
    }

    function _launchV3Named(address launcher, address quote, uint256 buyAmount, string memory name_)
        internal returns (Kid memory k, uint256 out)
    {
        (CubitForgeV3.LaunchParams memory p, address predictedToken, address predictedHook) =
            _v3Params(launcher, quote, buyAmount, name_);
        vm.deal(launcher, launcher.balance + FEE);
        _mintQuote(quote, launcher, buyAmount);
        _approve(quote, launcher, address(forgeV3));
        uint256 value = FEE + (quote == ETH ? buyAmount : 0);
        bytes memory code = _code(quote);
        vm.prank(launcher);
        (address t, address h, uint256 bought) = forgeV3.launch{value: value}(p, code);
        require(t == predictedToken, "child token address");
        require(h == predictedHook, "child hook address");
        k = Kid(CubitForgeToken(t), ICubitQuoteHook(h), ICubitQuoteHook(h).poolKey(), quote, quote != ETH);
        out = bought;
    }

    // ------------------------------------------------------------------ trading, either orientation

    /// @dev A buy pays the quote: zeroForOne when the quote is currency0 (ETH children), oneForZero otherwise.
    function _buyKid(Kid memory k, address who, uint256 quoteIn) internal returns (uint256 tokensOut) {
        _mintQuote(k.quote, who, quoteIn);
        _approve(k.quote, who, address(swapper));
        uint256 before = k.token.balanceOf(who);
        vm.prank(who);
        swapper.swap{value: k.quote == ETH ? quoteIn : 0}(k.key, !k.tokenFirst, -int256(quoteIn));
        tokensOut = k.token.balanceOf(who) - before;
    }

    function _sellKid(Kid memory k, address who, uint256 tokensIn) internal returns (uint256 quoteOut) {
        vm.prank(who);
        k.token.approve(address(swapper), type(uint256).max);
        uint256 before = _balance(k.quote, who);
        vm.prank(who);
        swapper.swap(k.key, k.tokenFirst, -int256(tokensIn));
        quoteOut = _balance(k.quote, who) - before;
    }

    /// @dev Exact-output trades: a buy of exactly `tokensOut`, a sale for exactly `quoteOut`.
    function _buyKidExactOut(Kid memory k, address who, uint256 tokensOut, uint256 budget) internal returns (uint256 paid) {
        _mintQuote(k.quote, who, budget);
        _approve(k.quote, who, address(swapper));
        uint256 before = _balance(k.quote, who);
        vm.prank(who);
        swapper.swap{value: k.quote == ETH ? budget : 0}(k.key, !k.tokenFirst, int256(tokensOut));
        paid = before - _balance(k.quote, who);
    }

    function _sellKidExactOut(Kid memory k, address who, uint256 quoteOut) internal returns (uint256 tokensIn) {
        vm.prank(who);
        k.token.approve(address(swapper), type(uint256).max);
        uint256 before = k.token.balanceOf(who);
        vm.prank(who);
        swapper.swap(k.key, k.tokenFirst, int256(quoteOut));
        tokensIn = before - k.token.balanceOf(who);
    }

    function _kidTick(Kid memory k) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(k.key.toId());
    }

    function _kidSqrtP(Kid memory k) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(k.key.toId());
    }

    /// @dev The same books as a v2 child, whatever the orientation: every claim booked to exactly one account.
    function _assertKidBooks(Kid memory k) internal view {
        assertEq(
            manager.balanceOf(address(k.hook), uint256(uint160(k.quote))),
            k.hook.pendingFloorQuote() + k.hook.teamAccrued() + k.hook.wallIdleQuote(),
            "quote claims differ from the books"
        );
        assertEq(
            manager.balanceOf(address(k.hook), uint256(uint160(address(k.token)))),
            k.hook.pendingAbsorbedTokens(),
            "token claims differ from the absorbed queue"
        );
        assertEq(k.token.balanceOf(address(k.hook)), 0, "hook holds raw tokens");
        assertEq(_balance(k.quote, address(k.hook)), 0, "hook holds raw quote");
        assertEq(k.token.totalSupply() + k.token.totalBurned(), k.token.TOTAL_SUPPLY(), "supply accounting");
        _assertKidWalls(k);
    }

    /// @dev Active walls are distinct and funded; the nearest is the lowest active tick for a quote-first child and
    ///      the highest for a token-first one; every active wall is on the quote side of the price or merely entered.
    function _assertKidWalls(Kid memory k) internal view {
        uint256 n = k.hook.activeWallCount();
        int24 nearestSeen = k.tokenFirst ? type(int24).min : type(int24).max;
        for (uint256 i; i < n; i++) {
            uint256 id = k.hook.activeWallId(i);
            (int24 lower, uint128 liquidity,,) = k.hook.walls(id);
            assertGt(liquidity, 0, "an active wall holds no liquidity");
            if (k.tokenFirst ? lower > nearestSeen : lower < nearestSeen) nearestSeen = lower;
            for (uint256 j; j < i; j++) assertTrue(k.hook.activeWallId(j) != id, "a wall is listed twice");
        }
        (bool exists, int24 nearest) = k.hook.nearestWallTick();
        assertEq(exists, n != 0, "nearest wall flag");
        if (n != 0) assertEq(nearest, nearestSeen, "nearest wall");
        uint256 idle;
        for (uint256 id; id < k.hook.wallCount(); id++) {
            (,, uint256 wallIdle,) = k.hook.walls(id);
            idle += wallIdle;
        }
        assertEq(idle, k.hook.wallIdleQuote(), "per-wall idle quote does not sum to the book");
    }

    /// @dev No fully crossed wall remains after a sale.
    function _assertNoCrossedKidWall(Kid memory k) internal view {
        (bool exists, int24 nearest) = k.hook.nearestWallTick();
        if (!exists) return;
        if (k.tokenFirst) assertGe(_kidTick(k), nearest, "a fully crossed wall remains");
        else assertLt(_kidTick(k), nearest + 10, "a fully crossed wall remains");
    }
}
