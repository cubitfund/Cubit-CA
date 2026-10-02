// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
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
import {RedesignBase} from "./RedesignBase.sol";
import {MockQuote, MockNoReturnQuote, QuoteSwapper, RefusingGovernanceVault} from "./QuoteMocks.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {CubitHook} from "../../../src/CubitHook.sol";
import {CubitForge, CubitForgeToken} from "../../../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../../../src/periphery/CubitForgeV2.sol";
import {CubitGovernanceVault} from "../../../src/periphery/CubitGovernanceVault.sol";
import {CubitQuoteHook} from "../../../src/quote/CubitQuoteHook.sol";
import {ICubitQuoteHook} from "../../../src/quote/ICubitQuoteHook.sol";
import {QuoteBandLib} from "../../../src/quote/QuoteBandLib.sol";
import {QuoteTaxes} from "../../../src/quote/QuoteTaxes.sol";
import {BandLib} from "../../../src/libraries/BandLib.sol";

/// @notice Shared set-up and helpers of the launchpad v2 suites: children paired with native ETH or an ERC-20 quote. The ERC-20 quotes are mocks placed
///         at the mainnet addresses of USDC, USDT, WBTC and TSLAon, so that the token-above-quote ordering is exercised
///         against the real addresses (TSLAon, 0xf6b1…, leaves few token addresses above it).
abstract contract QuoteBase is RedesignBase {
    using StateLibrary for IPoolManager;

    address internal constant ETH = address(0);
    address internal USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal TSLAON = 0xf6b1117ec07684D3958caD8BEb1b302bfD21103f;
    uint8 internal constant FORGE_BIT = 8;
    uint256 internal constant FEE = 0.005 ether;

    CubitForgeV2 internal forgeV2;
    QuoteSwapper internal swapper;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal childTeam = makeAddr("childTeam");

    /// @dev The taxes the next launch uses: CUBIT's by default; a test sets others before calling _params/_launch.
    QuoteTaxes.Taxes internal taxes;

    struct Child {
        CubitForgeToken token;
        CubitQuoteHook hook;
        PoolKey key;
        address quote;
    }

    function setUp() public virtual override {
        super.setUp();
        taxes = QuoteTaxes.cubit();
        _setUpQuotes();
        governanceVault = new CubitGovernanceVault();
        forgeV2 = new CubitForgeV2(hook, FEE, address(governanceVault), _quotes(), _values());
        vm.startPrank(team);
        registry.setForge(address(forgeV2));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
        swapper = new QuoteSwapper(manager);
    }

    /// @dev Mocks at the real addresses; the fork suite uses the real tokens instead, and the Medusa harness deploys
    ///      them at ordinary addresses (Medusa does not run code placed with vm.etch). The quote addresses are
    ///      therefore variables, not constants.
    function _setUpQuotes() internal virtual {
        vm.etch(USDC, address(new MockQuote("USDC", 6)).code);
        vm.etch(WBTC, address(new MockQuote("WBTC", 8)).code);
        vm.etch(TSLAON, address(new MockQuote("TSLAon", 18)).code);
        vm.etch(USDT, address(new MockNoReturnQuote()).code);
    }

    function _quotes() internal view virtual returns (address[] memory q) {
        q = new address[](5);
        (q[0], q[1], q[2], q[3], q[4]) = (ETH, USDC, USDT, WBTC, TSLAON);
    }

    /// @dev Roughly 3.75 ETH each, at illustrative prices.
    function _values() internal view virtual returns (uint256[] memory v) {
        v = new uint256[](5);
        (v[0], v[1], v[2], v[3], v[4]) = (3.75 ether, 15_000e6, 15_000e6, 0.15e8, 35e18);
    }

    // ------------------------------------------------------------------ launch helpers

    function _mintQuote(address quote, address to, uint256 amount) internal virtual {
        if (quote == ETH) vm.deal(to, to.balance + amount);
        else MockQuote(quote).mint(to, amount); // same selector on the USDT mock
    }

    function _approve(address quote, address owner, address spender) internal virtual {
        if (quote == ETH) return;
        vm.startPrank(owner);
        if (quote == USDT) {
            MockNoReturnQuote(USDT).approve(spender, 0);
            MockNoReturnQuote(USDT).approve(spender, type(uint256).max);
        } else {
            MockQuote(quote).approve(spender, type(uint256).max);
        }
        vm.stopPrank();
    }

    function _balance(address quote, address who) internal view returns (uint256) {
        return quote == ETH ? who.balance : MockQuote(quote).balanceOf(who);
    }

    /// @dev CREATE2 address in plain Solidity: Medusa, which runs this set-up too, has no computeCreate2Address cheatcode.
    function _create2(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev The first token salt whose child token sorts above (or, with `below`, under) the quote.
    function _tokenSalt(address launcher, address quote, string memory name_, string memory symbol_, bool below)
        internal view returns (bytes32 salt, address predicted)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode(name_, symbol_)));
        for (uint256 i; i < 100_000; i++) {
            salt = bytes32(i);
            predicted = _create2(keccak256(abi.encode(launcher, salt)), codeHash, address(forgeV2));
            if ((uint160(predicted) > uint160(quote)) != below && predicted.code.length == 0) return (salt, predicted);
        }
        revert("no token salt");
    }

    function _hookSalt(address launcher, address token_, address quote, address team_)
        internal view returns (bytes32, address)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(CubitQuoteHook).creationCode,
            abi.encode(manager, token_, team_, quote, forgeV2.launchValue(quote), taxes)
        ));
        for (uint256 i; i < 1_000_000; i++) {
            address candidate =
                _create2(keccak256(abi.encode(launcher, bytes32(i))), initCodeHash, address(forgeV2));
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == FLAGS && candidate.code.length == 0) return (bytes32(i), candidate);
        }
        revert("no hook salt");
    }

    function _params(address launcher, address quote, uint256 buyAmount)
        internal view returns (CubitForgeV2.LaunchParams memory p, address token_, address hook_)
    {
        (bytes32 tokenSalt, address predicted) = _tokenSalt(launcher, quote, "Child", "CHLD", false);
        (bytes32 hookSalt, address predictedHook) = _hookSalt(launcher, predicted, quote, childTeam);
        p = CubitForgeV2.LaunchParams({
            name: "Child", symbol: "CHLD", team: childTeam, quote: quote,
            tokenSalt: tokenSalt, hookSalt: hookSalt, buyAmount: buyAmount, taxes: taxes
        });
        (token_, hook_) = (predicted, predictedHook);
    }

    function _launch(address launcher, address quote, uint256 buyAmount) internal returns (Child memory c, uint256 out) {
        (CubitForgeV2.LaunchParams memory p, address predictedToken, address predictedHook) =
            _params(launcher, quote, buyAmount);
        vm.deal(launcher, launcher.balance + FEE);
        _mintQuote(quote, launcher, buyAmount);
        _approve(quote, launcher, address(forgeV2));
        uint256 value = FEE + (quote == ETH ? buyAmount : 0);
        vm.prank(launcher);
        (address t, address h, uint256 bought) = forgeV2.launch{value: value}(p, type(CubitQuoteHook).creationCode);
        // require, not assertEq: Medusa runs this set-up and has no vm.assertEq cheatcode.
        require(t == predictedToken, "child token address");
        require(h == predictedHook, "child hook address");
        c = Child(CubitForgeToken(t), CubitQuoteHook(h), CubitQuoteHook(h).poolKey(), quote);
        out = bought;
    }

    // ------------------------------------------------------------------ trading helpers

    function _buyChild(Child memory c, address who, uint256 quoteIn) internal returns (uint256 tokensOut) {
        _mintQuote(c.quote, who, quoteIn);
        _approve(c.quote, who, address(swapper));
        uint256 before = c.token.balanceOf(who);
        vm.prank(who);
        swapper.swap{value: c.quote == ETH ? quoteIn : 0}(c.key, true, -int256(quoteIn));
        tokensOut = c.token.balanceOf(who) - before;
    }

    function _sellChild(Child memory c, address who, uint256 tokensIn) internal returns (uint256 quoteOut) {
        vm.prank(who);
        c.token.approve(address(swapper), type(uint256).max);
        uint256 before = _balance(c.quote, who);
        vm.prank(who);
        swapper.swap(c.key, false, -int256(tokensIn));
        quoteOut = _balance(c.quote, who) - before;
    }

    function _childTick(Child memory c) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(c.hook.poolId());
    }

    function _childSqrtP(Child memory c) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(c.hook.poolId());
    }

    /// @dev Every quote unit and token the hook owns is a claim in the PoolManager, booked to exactly one account.
    function _assertChildBooks(Child memory c) internal view {
        assertEq(
            manager.balanceOf(address(c.hook), uint256(uint160(c.quote))),
            c.hook.pendingFloorQuote() + c.hook.teamAccrued() + c.hook.wallIdleQuote(),
            "quote claims differ from the books"
        );
        assertEq(
            manager.balanceOf(address(c.hook), uint256(uint160(address(c.token)))),
            c.hook.pendingAbsorbedTokens(),
            "token claims differ from the absorbed queue"
        );
        assertEq(c.token.balanceOf(address(c.hook)), 0, "hook holds raw tokens");
        assertEq(_balance(c.quote, address(c.hook)), 0, "hook holds raw quote");
        assertEq(c.token.totalSupply() + c.token.totalBurned(), c.token.TOTAL_SUPPLY(), "supply accounting");
        _assertWallIndex(c);
    }

    /// @dev The active list holds distinct walls with liquidity, the nearest tick is the lowest active
    ///      lower tick, and the quote earmarked per wall sums to the book's total.
    function _assertWallIndex(Child memory c) internal view {
        uint256 n = c.hook.activeWallCount();
        int24 lowest = type(int24).max;
        for (uint256 i; i < n; i++) {
            uint256 id = c.hook.activeWallId(i);
            (int24 lower, uint128 liquidity,,) = c.hook.walls(id);
            assertGt(liquidity, 0, "an active wall holds no liquidity");
            if (lower < lowest) lowest = lower;
            for (uint256 j; j < i; j++) assertTrue(c.hook.activeWallId(j) != id, "a wall is listed twice");
        }
        (bool exists, int24 nearest) = c.hook.nearestWallTick();
        assertEq(exists, n != 0, "nearest wall flag");
        if (n != 0) assertEq(nearest, lowest, "nearest wall is not the lowest active tick");
        uint256 idle;
        for (uint256 id; id < c.hook.wallCount(); id++) {
            (,, uint256 wallIdle,) = c.hook.walls(id);
            idle += wallIdle;
        }
        assertEq(idle, c.hook.wallIdleQuote(), "per-wall idle quote does not sum to the book");
    }

    function _assertNoCrossedChildWall(Child memory c) internal view {
        (bool exists, int24 nearest) = c.hook.nearestWallTick();
        if (exists) assertLt(_childTick(c), nearest + 10, "a fully crossed wall remains");
    }
}
