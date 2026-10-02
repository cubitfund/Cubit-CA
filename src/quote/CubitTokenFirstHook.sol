// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {ICubitQuoteHook} from "./ICubitQuoteHook.sol";
import {TokenFirstBandLib} from "./TokenFirstBandLib.sol";
import {TokenFirstWallLib} from "./TokenFirstWallLib.sol";
import {QuoteTaxes} from "./QuoteTaxes.sol";
import {CubitToken} from "../CubitToken.sol";
import {BandLib} from "../libraries/BandLib.sol";
import {ICubitForgeSink, ICubitGovernanceVault} from "../interfaces/ICubitV2.sol";

/// @title CubitTokenFirstHook — the market maker of a token-first launchpad child
/// @notice CubitQuoteHook's mechanism, unchanged, in the opposite pool orientation: the child token is currency0 and its
///         ERC-20 quote (USDC, USDT, WBTC, a tokenized stock) currency1, so the pool reads TOKEN/QUOTE for every
///         explorer and aggregator that takes currency0 as the base. The hook is the ONLY liquidity provider of its
///         pool and runs the same two books:
///
///           THE WALLS  — narrow quote buy positions UNDER the price, placed by every sale with its wall share at 40%
///                        of the current price + 60% of the launch price, or 1% under the price when that target is
///                        not under the market (at or below launch). Merged per tick, never moved.
///           THE BAND   — one wide token position, [first spacing above the launch tick, maxUsableTick], placed once
///                        at initialization with the whole supply and never withdrawn.
///
///         Taxes are taken on the quote leg, at the rates the launcher chose at launch within QuoteTaxes' bounds,
///         immutable. There is no owner, no guardian, no pause, no mint, no upgrade, no withdrawal. Only a Forge child
///         uses this hook: it delivers the tokens its crossed walls absorb to the governance vault named by the Forge
///         that deployed its token.
///
/// @dev ORIENTATION. The token is always currency0: the Forge makes the child token's address sort below the quote's,
///      and the constructor refuses anything else (native ETH, address zero, cannot be currency1: an ETH child uses
///      CubitQuoteHook). The pool price is quote per token and moves with the token price: a buy is oneForZero (quote
///      in), a sale zeroForOne. Every tick here is the mirror of CubitQuoteHook's (TokenFirstBandLib).
///
///      The hook never transfers the quote itself: it holds it as ERC-6909 claims in the PoolManager and pays the team
///      with `take`. The quote's own rules still bind the pool: an issuer that pauses its token, blocks the
///      PoolManager or charges a transfer fee freezes this pool.
contract CubitTokenFirstHook is ICubitQuoteHook, IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // =====================================================================================
    // Immutable economics — CubitHook's, with no setter for any of these.
    // =====================================================================================
    uint256 public constant BPS = 10_000;
    /// @notice Tax on buys, inclusive, on the quote leg, all to the team. Chosen at launch, immutable.
    uint256 public immutable BUY_TAX_BPS;
    /// @notice Tax on sales, of the gross quote output: SELL_FLOOR_BPS to the walls plus SELL_TEAM_BPS to the team.
    uint256 public immutable SELL_TAX_BPS;
    uint256 public immutable SELL_FLOOR_BPS;
    uint256 public immutable SELL_TEAM_BPS;
    uint256 public constant POOL_BPS = 8_000; // at least 80% of the supply is deposited in the band
    uint24 public constant POOL_FEE = 100; // 0.01% LP fee (one basis point), separate from hook taxes
    int24 public constant TICK_SPACING = 10; // wall width = 1 spacing = 0.10%; TokenFirstWallLib's bitmap assumes it
    uint256 public constant WALL_RETRACEMENT_BPS = BandLib.WALL_RETRACEMENT_BPS;
    uint256 public constant MAX_ACTIVE_WALLS = TokenFirstWallLib.MAX_ACTIVE_WALLS;
    /// @notice Bounds of the launch tick (see TokenFirstBandLib: CubitQuoteHook's, mirrored).
    int24 public constant MAX_LAUNCH_TICK = TokenFirstBandLib.MAX_LAUNCH_TICK;
    int24 public constant MIN_LAUNCH_TICK = TokenFirstBandLib.MIN_LAUNCH_TICK;
    /// @notice This child's pool is TOKEN/QUOTE: the token is currency0 (CubitQuoteHook's pools are QUOTE/TOKEN).
    bool public constant TOKEN_IS_CURRENCY0 = true;

    bytes32 public constant FLOOR_SALT = keccak256("CUBIT.FLOOR");
    bytes32 public constant BAND_SALT = keccak256("CUBIT.BAND");

    uint8 private constant ACTION_BOOTSTRAP = 1;
    uint8 private constant ACTION_CLAIM_TEAM = 4;
    uint8 private constant ACTION_DELIVER_ABSORBED = 5;

    IPoolManager public immutable poolManager;
    CubitToken public immutable token;
    address public immutable TEAM_ADDRESS;
    /// @inheritdoc ICubitQuoteHook
    Currency public immutable quote;
    /// @inheritdoc ICubitQuoteHook
    uint256 public immutable LAUNCH_QUOTE;
    uint160 public immutable INITIAL_SQRT_PRICE;
    uint256 public immutable MIN_POOL_SUPPLY;
    /// @notice A quarter of what the PoolManager allows on a single tick (see CubitHook).
    uint128 public immutable MAX_LIQUIDITY_PER_TICK;
    PoolId public immutable poolId;
    Currency internal immutable _token;
    uint256 internal immutable _quoteId;

    /// @dev The child token must sort before its quote, so that it is the pool's currency0.
    error TokenNotCurrency0();

    // =====================================================================================
    // Storage
    // =====================================================================================
    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @notice Wall share of sales and quote released by crossed walls, waiting for the same sale to place it.
    uint256 public pendingFloorQuote;
    TokenFirstWallLib.Book internal _walls;
    uint256 public pendingAbsorbedTokens; // child token claims from crossed walls, awaiting delivery

    Position internal _band;

    uint256 public teamAccrued;
    uint256 public teamPaidCumulative;
    uint256 public launchTimestamp;

    bool public initialized;
    bool private _busy;

    // =====================================================================================
    // Construction
    // =====================================================================================
    constructor(
        IPoolManager poolManager_,
        CubitToken token_,
        address team_,
        Currency quote_,
        uint256 launchQuote_,
        QuoteTaxes.Taxes memory taxes_
    ) {
        if (team_ == address(0)) revert ZeroAddress();
        if (!QuoteTaxes.valid(taxes_)) revert InvalidTaxes();
        if (address(token_) >= Currency.unwrap(quote_)) revert TokenNotCurrency0();
        if (Currency.unwrap(quote_).code.length == 0) revert ZeroAddress();
        (bool validPrice, uint160 sqrtPrice) = TokenFirstBandLib.launchSqrtPrice(launchQuote_, token_.TOTAL_SUPPLY());
        if (!validPrice) revert UnexpectedInitialPrice();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        poolManager = poolManager_;
        token = token_;
        TEAM_ADDRESS = team_;
        quote = quote_;
        LAUNCH_QUOTE = launchQuote_;
        BUY_TAX_BPS = taxes_.buyTeamBps;
        SELL_TEAM_BPS = taxes_.sellTeamBps;
        SELL_FLOOR_BPS = taxes_.sellWallBps;
        SELL_TAX_BPS = uint256(taxes_.sellTeamBps) + taxes_.sellWallBps;
        _token = Currency.wrap(address(token_));
        _quoteId = quote_.toId();
        INITIAL_SQRT_PRICE = sqrtPrice;
        MIN_POOL_SUPPLY = token_.TOTAL_SUPPLY() * POOL_BPS / BPS;
        MAX_LIQUIDITY_PER_TICK = BandLib.maxLiquidityPerTick(TICK_SPACING) / 4;
        poolId = poolKey().toId();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_busy) revert Reentrancy();
        _busy = true;
        _;
        _busy = false;
    }

    /// @notice CubitHook's six permissions, encoded in the hook address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The one and only pool this hook serves.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: _token,
            currency1: quote,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    // =====================================================================================
    // Hook callbacks
    // =====================================================================================

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Deploys the band (the whole deposit) in the same transaction as the pool initialisation.
    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!_isCanonical(key)) revert NotHookOwnedPool();
        if (initialized) revert AlreadyInitialized();
        if (sqrtPriceX96 != INITIAL_SQRT_PRICE) revert UnexpectedInitialPrice();
        if (token.hook() != address(this)) revert HookNotAuthorised();
        if (token.balanceOf(address(this)) < MIN_POOL_SUPPLY) revert SupplyNotDeposited();
        initialized = true;
        launchTimestamp = block.timestamp;
        poolManager.unlock(abi.encode(ACTION_BOOTSTRAP, uint256(0)));
        return IHooks.afterInitialize.selector;
    }

    /// @notice Single market maker: nobody but the hook can add liquidity.
    /// @inheritdoc IHooks
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != address(this)) revert ExternalLiquidityForbidden();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice Buy tax on exact-input buys (quote specified) and sell tax on exact-output sells (quote specified).
    ///         Always on the quote leg, never in the child token.
    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!params.zeroForOne) {
            // BUY, quote (currency1) -> token. Exact input: the specified currency is the quote.
            if (params.amountSpecified < 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 tax = _inclusiveBuyTax(amountIn);
                if (tax != 0) {
                    _creditBuyTax(amountIn, tax);
                    return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(tax)), 0), 0);
                }
            }
        } else if (params.amountSpecified > 0) {
            // SELL, token -> quote (zeroForOne), exact output: the pool produces out + tax and the hook keeps tax.
            uint256 out = uint256(params.amountSpecified);
            uint256 tax = FullMath.mulDivRoundingUp(out, SELL_TAX_BPS, BPS - SELL_TAX_BPS);
            if (tax > type(uint120).max) tax = type(uint120).max;
            if (tax != 0) {
                _creditSellTax(out + tax, tax);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(tax)), 0), 0);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Buy tax on exact-output buys and sell tax on exact-input sells. Every sale, in both modes, then empties
    ///         the walls it fully crossed and places the pending wall funds, before the next swap can reach either.
    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128 hookDelta)
    {
        int128 quoteDelta = delta.amount1();
        if (!params.zeroForOne) {
            // BUY exact output: tax / (paid + tax) is 3%, rounded up, like the inclusive input case.
            if (params.amountSpecified > 0 && quoteDelta < 0) {
                uint256 paid = uint256(uint128(-quoteDelta));
                uint256 tax = FullMath.mulDivRoundingUp(paid, BUY_TAX_BPS, BPS - BUY_TAX_BPS);
                if (tax != 0) {
                    _creditBuyTax(paid + tax, tax);
                    hookDelta = int128(uint128(tax));
                }
            }
        } else {
            if (params.amountSpecified < 0 && quoteDelta > 0) {
                // SELL exact input: SELL_TAX_BPS of the gross quote going out (walls + team).
                uint256 out = uint256(uint128(quoteDelta));
                uint256 tax = FullMath.mulDivRoundingUp(out, SELL_TAX_BPS, BPS);
                if (tax > out) tax = out;
                if (tax != 0) {
                    _creditSellTax(out, tax);
                    hookDelta = int128(uint128(tax));
                }
            }
            _collectCrossedWalls();
            _placeWall();
        }
        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ----------------------------------------------------------------------- tax helpers

    /// @dev ceil(amountIn × BUY_TAX_BPS), capped at uint120 and never the whole amount (see CubitHook).
    function _inclusiveBuyTax(uint256 amountIn) internal view returns (uint256 tax) {
        tax = FullMath.mulDivRoundingUp(amountIn, BUY_TAX_BPS, BPS);
        if (tax > type(uint120).max) tax = type(uint120).max;
        if (tax >= amountIn) tax = amountIn == 0 ? 0 : amountIn - 1;
    }

    /// @dev The entire buy tax goes to the team book.
    function _creditBuyTax(uint256 grossQuoteIn, uint256 tax) internal {
        teamAccrued += tax;
        poolManager.mint(address(this), _quoteId, tax);
        emit BuyTaxed(grossQuoteIn, 0, tax);
    }

    /// @dev Split the sell tax between walls and team: the team allocation rounds down, every remaining unit goes to
    ///      the walls. Only reached with a non-zero tax, hence a non-zero SELL_TAX_BPS.
    function _creditSellTax(uint256 grossQuoteOut, uint256 tax) internal {
        uint256 toTeam = tax * SELL_TEAM_BPS / SELL_TAX_BPS;
        uint256 toFloor = tax - toTeam;
        pendingFloorQuote += toFloor;
        teamAccrued += toTeam;
        poolManager.mint(address(this), _quoteId, tax);
        emit SellTaxed(grossQuoteOut, toFloor, toTeam);
    }

    // ----------------------------------------------------------------------- walls

    /// @dev Empty every wall this sale fully crossed (price under its lower tick). Their tokens wait for delivery; the
    ///      quote they release returns to the pending wall funds.
    function _collectCrossedWalls() internal {
        if (_walls.active.length == 0) return;
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        if (tick >= _walls.nearestTick) return;
        (uint256 tokens, uint256 released) = TokenFirstWallLib.collectCrossed(_walls, poolManager, poolKey(), tick);
        pendingFloorQuote += released;
        if (tokens != 0) {
            pendingAbsorbedTokens += tokens;
            emit TokensAbsorbed(tokens, pendingAbsorbedTokens);
        }
    }

    /// @dev Place the pending wall funds at 40% of the current price + 60% of the launch price, or 1% under the
    ///      current price when that target is not under the market. Only an amount too small to mint liquidity waits,
    ///      or funds at the top of the tick range. Never reverts the sale.
    ///      A wall is pure quote when its upper tick is at or under the pool tick.
    function _placeWall() internal {
        uint256 pending = pendingFloorQuote;
        if (pending == 0) return;
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 upper = TokenFirstBandLib.retracementWallUpper(INITIAL_SQRT_PRICE, sqrtP, TICK_SPACING);
        if (upper > tick) upper = TokenFirstBandLib.underMarketWallUpper(sqrtP, TICK_SPACING);
        if (upper > tick) return;
        (uint256 freshUsed, uint256 tokenFees) = TokenFirstWallLib.fund(
            _walls, poolManager, poolKey(), upper - TICK_SPACING, pending, MAX_LIQUIDITY_PER_TICK
        );
        pendingFloorQuote = pending - freshUsed;
        pendingAbsorbedTokens += tokenFees;
    }

    // =====================================================================================
    // Public, permissionless functions
    // =====================================================================================

    /// @notice Deliver the child tokens that crossed walls absorbed to the launchpad governance vault, where they are
    ///         locked. Anyone can call; the caller chooses no recipient or amount.
    function deliverAbsorbed() external nonReentrant {
        uint256 amount = pendingAbsorbedTokens;
        if (amount == 0) return;
        address sink = absorbedTokenSink();
        pendingAbsorbedTokens = 0;
        poolManager.unlock(abi.encode(ACTION_DELIVER_ABSORBED, amount));
        if (!token.transfer(sink, amount)) revert HookNotAuthorised();
        ICubitGovernanceVault(sink).lockUntracked(address(token));
        emit AbsorbedDelivered(sink, amount);
    }

    /// @notice Push the accrued team share, in the quote, to the immutable TEAM_ADDRESS. Anyone can call.
    function claimTeam() external nonReentrant {
        if (teamAccrued == 0) return;
        poolManager.unlock(abi.encode(ACTION_CLAIM_TEAM, uint256(0)));
    }

    // =====================================================================================
    // Unlock callback
    // =====================================================================================

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (action == ACTION_BOOTSTRAP) _bootstrap();
        else if (action == ACTION_CLAIM_TEAM) _claimTeam();
        else if (action == ACTION_DELIVER_ABSORBED) {
            poolManager.burn(address(this), _token.toId(), amount);
            poolManager.take(_token, address(this), amount);
        }
        return "";
    }

    /// @dev Place the whole deposit in ONE single-sided token position, [lower, maxUsableTick], `lower` being the
    ///      first spacing multiple above the opening tick. The remainder under one liquidity unit's worth is burned.
    ///      The band must take at least MIN_POOL_SUPPLY: should the per-tick liquidity ceiling ever bind, the launch
    ///      reverts instead of burning the supply.
    function _bootstrap() internal {
        uint256 deposit = token.balanceOf(address(this));
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 lower = BandLib.floorToSpacing(tick, TICK_SPACING) + TICK_SPACING;
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        (uint128 liquidity,) = BandLib.liquidityForEth(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), deposit, MAX_LIQUIDITY_PER_TICK
        );
        BalanceDelta d = _modify(lower, upper, int256(uint256(liquidity)), BAND_SALT);
        // Unreachable by construction (lower > tick): the band never takes quote.
        // slither-disable-next-line reentrancy-balance
        if (d.amount1() != 0) revert UnexpectedInitialPrice();
        uint256 used = uint256(uint128(-d.amount0()));
        if (used < MIN_POOL_SUPPLY) revert SupplyNotDeposited();
        _band = Position(lower, upper, liquidity);

        poolManager.sync(_token);
        if (!token.transfer(address(poolManager), used)) revert HookNotAuthorised();
        poolManager.settle();

        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) {
            token.burn(dust);
            emit TokensBurned(dust, token.totalBurned());
        }
        emit BandBootstrapped(lower, upper, liquidity, used);
    }

    function _claimTeam() internal {
        uint256 amount = teamAccrued;
        teamAccrued = 0;
        teamPaidCumulative += amount;
        poolManager.burn(address(this), _quoteId, amount);
        poolManager.take(quote, TEAM_ADDRESS, amount);
        emit TeamPaid(amount, teamPaidCumulative);
    }

    // ----------------------------------------------------------------------- internals

    function _modify(int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt) internal returns (BalanceDelta d) {
        (d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        );
    }

    function _isCanonical(PoolKey calldata key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(token)
            && Currency.unwrap(key.currency1) == Currency.unwrap(quote) && key.fee == POOL_FEE
            && key.tickSpacing == TICK_SPACING && address(key.hooks) == address(this);
    }

    // =====================================================================================
    // Views
    // =====================================================================================

    function wallCount() external view returns (uint256) { return _walls.walls.length; }
    function activeWallCount() external view returns (uint256) { return _walls.active.length; }
    function activeWallId(uint256 index) external view returns (uint256) { return _walls.active[index]; }
    function latestWallId() external view returns (uint256) { return _walls.latestId; }
    /// @notice The active wall nearest to the market (the highest), the first a sale meets. `exists` is false when no
    ///         wall stands.
    function nearestWallTick() external view returns (bool exists, int24 lower) {
        if (_walls.active.length == 0) return (false, 0);
        return (true, _walls.nearestTick);
    }
    function wallIdleQuote() external view returns (uint256) { return _walls.idleQuote; }
    function walls(uint256 id)
        external view returns (int24 lower, uint128 liquidity, uint256 idleQuote, uint256 fundedQuote)
    {
        TokenFirstWallLib.Wall storage w = _walls.walls[id];
        return (w.lower, w.liquidity, w.idleQuote, w.fundedQuote);
    }
    function wallAmounts(uint160 sqrtP) external view returns (uint256 quoteAmount, uint256 tokens) {
        return TokenFirstWallLib.amounts(_walls, sqrtP, TICK_SPACING);
    }

    /// @inheritdoc ICubitQuoteHook
    function band() external view returns (int24 lower, int24 upper, uint128 liquidity) {
        return (_band.lower, _band.upper, _band.liquidity);
    }

    /// @inheritdoc ICubitQuoteHook
    function absorbedTokenSink() public view returns (address) {
        return ICubitForgeSink(token.deployer()).governanceVault();
    }
}
