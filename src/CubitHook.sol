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

import {ICubitHook} from "./interfaces/ICubitHook.sol";
import {CubitToken} from "./CubitToken.sol";
import {BandLib} from "./libraries/BandLib.sol";
import {WallLib} from "./libraries/WallLib.sol";
import {ICubitV2, ICubitVault, ICubitForgeSink, ICubitGovernanceVault} from "./interfaces/ICubitV2.sol";

/// @title CubitHook — the CUBIT market maker
/// @notice Uniswap v4 hook that is the ONLY liquidity provider of the CUBIT/ETH pool and
///         runs two strictly separated books:
///
///           THE WALLS            — narrow ETH buy positions under the spot, placed by every sale
///                                  with its 12% at 40% of the current price + 60% of the launch
///                                  price, or 1% under the price when that target is not under the
///                                  market (at or below launch). Merged per tick, never moved.
///           THE BAND (trading)   — one wide CUBIT position, [minUsableTick, launch tick], placed
///                                  once at initialization with the whole deposit (at least 80%
///                                  of the supply) and never withdrawn. 100% CUBIT at the launch
///                                  price; buys and sells move along its constant-product curve.
///
///         There is no owner, no guardian, no pause, no mint, no upgrade, no withdrawal (I6, I7).
///
/// @dev Accounting model: every wei of ETH and every CUBIT the hook owns outside its positions lives
///      inside the PoolManager as ERC-6909 claims. A wall the price has fully crossed holds only CUBIT:
///      the sale that crossed it empties it, and those CUBIT wait, isolated, for delivery to the vault's
///      reward reserve — the canonical router delivers them in the same transaction. A wall the price
///      only entered stays in place. Wall maintenance inside a swap uses only the PoolManager; the
///      delivery happens after the swap.
///
///      Tick orientation is the pool's (ETH is currency0): see BandLib. Every wall's tick is
///      permanent; the latest funding target may be above OR below the previous target.
contract CubitHook is ICubitHook, IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // =====================================================================================
    // Immutable economics (CONTRACT_SPEC §3) — no setter exists for any of these.
    // =====================================================================================
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 300; // 3% inclusive on the ETH leg of buys
    uint256 public constant BUY_FLOOR_BPS = 0; // compatibility getter: buys never fund walls
    uint256 public constant BUY_TEAM_BPS = 300; // 3%  -> team
    uint256 public constant SELL_TAX_BPS = 1_500; // 15% of gross ETH output
    uint256 public constant SELL_FLOOR_BPS = 1_200; // 12% -> pending wall funding
    uint256 public constant SELL_TEAM_BPS = 300; // 3% of the ETH leg of sells -> team
    uint256 public constant POOL_BPS = 8_000; // at least 80% of the supply is deposited in the band
    uint24 public constant POOL_FEE = 100; // 0.01% LP fee (one basis point), separate from hook taxes
    int24 public constant TICK_SPACING = 10; // wall width = 1 spacing = 0.10% (TBD T6 proposal)
    uint256 public constant WALL_RETRACEMENT_BPS = BandLib.WALL_RETRACEMENT_BPS;
    uint256 public immutable LAUNCH_ETH; // launch FDV in ETH, frozen at deployment

    bytes32 public constant FLOOR_SALT = keccak256("CUBIT.FLOOR");
    bytes32 public constant BAND_SALT = keccak256("CUBIT.BAND");

    uint8 private constant ACTION_BOOTSTRAP = 1;
    uint8 private constant ACTION_CLAIM_TEAM = 4;
    uint8 private constant ACTION_DELIVER_ABSORBED = 5;

    IPoolManager public immutable poolManager;
    CubitToken public immutable token;
    address public immutable TEAM_ADDRESS;
    uint160 public immutable INITIAL_SQRT_PRICE;
    /// @notice The smallest deposit the band accepts: POOL_BPS of the supply. The launch deposits
    ///         exactly this; a Forge child deposits its whole supply. The band takes all of it.
    uint256 public immutable MIN_POOL_SUPPLY;
    /// @notice The per-position liquidity ceiling: a quarter of what the PoolManager allows on a
    ///         single tick. Reachable in practice — a narrow ETH position at an extreme tick (a
    ///         very low CUBIT price) implies an enormous liquidity number — and exceeding it
    ///         reverts the whole deposit. Every deposit is capped and the surplus waits: clean
    ///         degradation, never a reverted sale.
    uint128 public immutable MAX_LIQUIDITY_PER_TICK;
    PoolId public immutable poolId;
    Currency internal immutable _cubit;

    // =====================================================================================
    // Storage
    // =====================================================================================
    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    // --- floor (the sacred book) ---
    uint256 public pendingFloorEth; // 12% of sales and ETH released by crossed walls; the same sale places it
    WallLib.Book internal _walls;
    uint256 public constant MAX_ACTIVE_WALLS = WallLib.MAX_ACTIVE_WALLS;
    uint256 public pendingAbsorbedTokens; // CUBIT claims from crossed walls, awaiting delivery to the vault

    // --- band (the trading book): placed once at bootstrap, never withdrawn ---
    Position internal _band;

    // --- accounts ---
    uint256 public teamAccrued;
    uint256 public teamPaidCumulative;
    // Prelaunch-only registry anchor; its peripheral addresses are replaceable by TEAM.
    address public v2;
    uint256 public launchTimestamp;

    event V2Configured(address indexed registry);
    error InvalidV2();

    // --- lifecycle ---
    bool public initialized;
    bool private _busy;

    // =====================================================================================
    // Construction
    // =====================================================================================
    constructor(IPoolManager poolManager_, CubitToken token_, address team_, uint256 launchEth_) {
        if (team_ == address(0)) revert ZeroAddress();
        if (launchEth_ < 1e12 || launchEth_ > 1_000_000 ether) revert UnexpectedInitialPrice();
        LAUNCH_ETH = launchEth_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        poolManager = poolManager_;
        token = token_;
        TEAM_ADDRESS = team_;
        _cubit = Currency.wrap(address(token_));
        INITIAL_SQRT_PRICE = uint160(BandLib.sqrtPriceForRatio(launchEth_, token_.TOTAL_SUPPLY()));
        MIN_POOL_SUPPLY = token_.TOTAL_SUPPLY() * POOL_BPS / BPS;
        // A quarter of the pool's ceiling: v4 enforces it on `liquidityGross`, summed over every
        // position touching a tick, and up to three of ours can share one (the band's top and the
        // bounds of two adjacent walls). The cap only binds in the collapsed regime, where a
        // quarter still absorbs far more ETH than exists.
        MAX_LIQUIDITY_PER_TICK = BandLib.maxLiquidityPerTick(TICK_SPACING) / 4;
        poolId = poolKey().toId();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Freeze the registry anchor before launch. Its own setters manage peripherals.
    function configureV2(address registry) external {
        if (msg.sender != token.deployer() || initialized || v2 != address(0)) revert InvalidV2();
        if (registry.code.length == 0 || ICubitV2(registry).hook() != address(this) ||
            ICubitV2(registry).enabledFeatures() != 0 ||
            ICubitVault(ICubitV2(registry).vault()).hook() != address(this)) revert InvalidV2();
        v2 = registry;
        emit V2Configured(registry);
    }

    modifier nonReentrant() {
        if (_busy) revert Reentrancy();
        _busy = true;
        _;
        _busy = false;
    }

    /// @notice The six permissions encoded in the hook address (CONTRACT_SPEC §2).
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
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: _cubit,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    // =====================================================================================
    // Hook callbacks — taxes, wall placement and isolation of crossed wall inventory
    // =====================================================================================

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Deploys the band (the whole deposit, at least 80% of the supply) in the same
    ///         transaction as the pool initialisation: there is no block in which a swap can
    ///         precede the order book (CONTRACT_SPEC §10 "premier bloc").
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
        // initialize() is not run inside a lock: open our own to deploy the band.
        poolManager.unlock(abi.encode(ACTION_BOOTSTRAP, address(0)));
        return IHooks.afterInitialize.selector;
    }

    /// @notice Single market maker (I4): nobody but the hook can add liquidity.
    /// @dev    The PoolManager does not call hooks for the hook's own modifications
    ///         (`noSelfCall`), so any invocation here comes from a third party.
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

    /// @notice Buy tax on exact-input buys (ETH specified) and sell tax on exact-output sells
    ///         (ETH specified). Always on the ETH leg, never in CUBIT.
    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.zeroForOne) {
            // BUY, ETH -> CUBIT. Exact input: the specified currency is ETH.
            if (params.amountSpecified < 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 tax = _inclusiveBuyTax(amountIn);
                if (tax != 0) {
                    _creditBuyTax(amountIn, tax);
                    return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(tax)), 0), 0);
                }
            }
        } else if (params.amountSpecified > 0) {
            // SELL, CUBIT -> ETH, exact output: the specified currency is ETH. The pool
            // produces out + tax and the hook keeps tax so the seller nets 85%.
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

    /// @notice Buy tax on exact-output buys (ETH is the unspecified input) and sell tax on
    ///         exact-input sells (ETH is the unspecified output). Every sale, in both modes, then
    ///         empties the walls it fully crossed and places the pending wall funds at the current
    ///         40/60 target (1% under the price below launch), before the next swap can reach either,
    ///         including within the same unlock.
    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128 hookDelta)
    {
        int128 ethDelta = delta.amount0();
        if (params.zeroForOne) {
            // BUY exact output: the user paid `paid` ETH for the pool leg; the tax is added on
            // top so that tax / (paid + tax) is 3%, rounded up, like the inclusive input case.
            if (params.amountSpecified > 0 && ethDelta < 0) {
                uint256 paid = uint256(uint128(-ethDelta));
                uint256 tax = FullMath.mulDivRoundingUp(paid, BUY_TAX_BPS, BPS - BUY_TAX_BPS);
                if (tax != 0) {
                    _creditBuyTax(paid + tax, tax);
                    hookDelta = int128(uint128(tax));
                }
            }
        } else {
            if (params.amountSpecified < 0 && ethDelta > 0) {
                // SELL exact input: 15% of the gross ETH going out (12% walls + 3% team).
                uint256 out = uint256(uint128(ethDelta));
                uint256 tax = FullMath.mulDivRoundingUp(out, SELL_TAX_BPS, BPS);
                if (tax > out) tax = out;
                if (tax != 0) {
                    _creditSellTax(out, tax);
                    hookDelta = int128(uint128(tax));
                }
            }
            // Exact-output sales were taxed in beforeSwap: both modes reach this point with their 12% pending.
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

    /// @dev ceil(amountIn × 3%), but never the whole amount (the pool rejects a zero swap):
    ///      rounding up removes any repeatable under-taxed dust swap.
    ///      A swap larger than `type(uint120).max` wei cannot have its tax represented in the
    ///      int128 delta, so the tax is CAPPED rather than skipped: an untaxed whale is a worse
    ///      failure than a slightly under-taxed one. (Unreachable in practice — that is more ETH
    ///      than exists — but a silent hole is not a failure mode worth leaving in.)
    function _inclusiveBuyTax(uint256 amountIn) internal pure returns (uint256 tax) {
        tax = FullMath.mulDivRoundingUp(amountIn, BUY_TAX_BPS, BPS);
        if (tax > type(uint120).max) tax = type(uint120).max;
        if (tax >= amountIn) tax = amountIn == 0 ? 0 : amountIn - 1;
    }

    /// @dev The entire buy tax goes to the team book.
    ///      Preserve the BuyTaxed ABI with an explicitly zero wall allocation.
    function _creditBuyTax(uint256 grossEthIn, uint256 tax) internal {
        teamAccrued += tax;
        poolManager.mint(address(this), 0, tax);
        emit BuyTaxed(grossEthIn, 0, tax);
    }

    /// @dev Split the sell tax 12/3. Round the team allocation down and give all remaining
    ///      wei to pending walls.
    function _creditSellTax(uint256 grossEthOut, uint256 tax) internal {
        uint256 toTeam = tax * SELL_TEAM_BPS / SELL_TAX_BPS;
        uint256 toFloor = tax - toTeam;
        pendingFloorEth += toFloor;
        teamAccrued += toTeam;
        poolManager.mint(address(this), 0, tax);
        emit SellTaxed(grossEthOut, toFloor, toTeam);
    }

    // ----------------------------------------------------------------------- walls

    /// @dev Empty every wall this sale fully crossed, however many. Their CUBIT wait for delivery; the ETH
    ///      they release (realized fees and earmarked dust) returns to the pending wall funds.
    function _collectCrossedWalls() internal {
        if (_walls.active.length == 0) return;
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        if (tick < _walls.nearestTick + TICK_SPACING) return;
        (uint256 tokens, uint256 eth) = WallLib.collectCrossed(_walls, poolManager, poolKey(), tick);
        pendingFloorEth += eth;
        if (tokens != 0) {
            pendingAbsorbedTokens += tokens;
            emit TokensAbsorbed(tokens, pendingAbsorbedTokens);
        }
    }

    /// @dev Place the pending wall funds at 40% of the current price + 60% of the launch price. The range
    ///      must lie strictly above the pool tick to be pure ETH: at or below the launch price that target
    ///      sits at or above the market, so the wall goes 1% under the current price instead. Funds must not
    ///      pile up for a later sale: its seller could push the price up first, place them high and sell
    ///      into them. Only an amount too small to mint liquidity waits, or funds at the top of the tick
    ///      range, where no position fits under the price. Never reverts the sale.
    function _placeWall() internal {
        uint256 pending = pendingFloorEth;
        if (pending == 0) return;
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 lower = BandLib.retracementWallTarget(INITIAL_SQRT_PRICE, sqrtP, TICK_SPACING);
        if (tick >= lower) lower = BandLib.underMarketWallTarget(sqrtP, TICK_SPACING);
        if (tick >= lower) return;
        (uint256 freshUsed, uint256 tokenFees) =
            WallLib.fund(_walls, poolManager, poolKey(), lower, pending, MAX_LIQUIDITY_PER_TICK);
        pendingFloorEth = pending - freshUsed;
        pendingAbsorbedTokens += tokenFees;
    }

    // =====================================================================================
    // Public, permissionless functions
    // =====================================================================================

    /// @notice Deliver the CUBIT that crossed walls absorbed: to the registry's vault reward reserve or,
    ///         for a Forge child without a registry, to the launchpad governance vault. Anyone can call;
    ///         the canonical router calls it after each sale. The caller chooses no recipient or amount.
    function deliverAbsorbed() external nonReentrant {
        uint256 amount = pendingAbsorbedTokens;
        if (amount == 0) return;
        address sink = absorbedTokenSink();
        pendingAbsorbedTokens = 0;
        poolManager.unlock(abi.encode(ACTION_DELIVER_ABSORBED, address(0), amount));
        if (v2 != address(0)) {
            if (!token.approve(sink, amount)) revert HookNotAuthorised();
            ICubitVault(sink).fundRewardReserve(amount);
        } else {
            if (!token.transfer(sink, amount)) revert HookNotAuthorised();
            ICubitGovernanceVault(sink).lockUntracked(address(token));
        }
        emit AbsorbedDelivered(sink, amount);
    }

    /// @notice Push the accrued team share to the immutable TEAM_ADDRESS. Anyone can call.
    function claimTeam() external nonReentrant {
        if (teamAccrued == 0) return;
        poolManager.unlock(abi.encode(ACTION_CLAIM_TEAM, msg.sender));
    }

    // =====================================================================================
    // Unlock callback — bootstrap, account claims and delivery of absorbed inventory
    // =====================================================================================

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action,) = abi.decode(data, (uint8, address));
        if (action == ACTION_BOOTSTRAP) _bootstrap();
        else if (action == ACTION_CLAIM_TEAM) _claimTeam();
        else if (action == ACTION_DELIVER_ABSORBED) {
            (,, uint256 amount) = abi.decode(data, (uint8, address, uint256));
            poolManager.burn(address(this), _cubit.toId(), amount);
            poolManager.take(_cubit, address(this), amount);
        }
        return "";
    }

    /// @dev Place the whole deposit in ONE single-sided CUBIT position, [minUsableTick, upper].
    ///      `upper` is the opening tick rounded DOWN to the spacing: the range lies entirely below
    ///      the spot and holds no ETH (rounding up would make it live and demand ETH), and the
    ///      pool opens less than one spacing above it. Integer liquidity cannot take the deposit
    ///      to the wei: the remainder (under one liquidity unit's worth) is burned, so the hook
    ///      keeps neither a raw token nor a claim.
    function _bootstrap() internal {
        uint256 deposit = token.balanceOf(address(this));
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = BandLib.floorToSpacing(tick, TICK_SPACING);
        (uint128 liquidity,) = BandLib.liquidityForTokens(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), deposit, MAX_LIQUIDITY_PER_TICK
        );
        BalanceDelta d = _modify(lower, upper, int256(uint256(liquidity)), BAND_SALT);
        // Unreachable by construction (upper <= tick); checked so the absence of an ETH leg is
        // never taken on trust. `d` is the manager's delta for this very call, not a balance, and
        // the manager never calls back into its own hook (noSelfCall): no stale balance reaches it.
        // slither-disable-next-line reentrancy-balance
        if (d.amount0() != 0) revert UnexpectedInitialPrice();
        uint256 used = uint256(uint128(-d.amount1()));
        _band = Position(lower, upper, liquidity);

        poolManager.sync(_cubit);
        // CubitToken is this repository's own OZ ERC-20: it returns true or reverts. Checked
        // anyway so a reader never has to take that on trust.
        if (!token.transfer(address(poolManager), used)) revert HookNotAuthorised();
        poolManager.settle();

        // Read the live balance rather than `deposit - used`: nothing can land in between, and a
        // fresh read keeps that true without relying on it.
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
        poolManager.burn(address(this), 0, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, TEAM_ADDRESS, amount);
        emit TeamPaid(amount, teamPaidCumulative);
    }

    // ----------------------------------------------------------------------- internals

    /// @dev The hook's own liquidity primitive, used once for the band. Walls go through WallLib.
    function _modify(int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt) internal returns (BalanceDelta d) {
        (d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        );
    }

    function _isCanonical(PoolKey calldata key) internal view returns (bool) {
        return key.currency0.isAddressZero() && Currency.unwrap(key.currency1) == address(token) && key.fee == POOL_FEE
            && key.tickSpacing == TICK_SPACING && address(key.hooks) == address(this);
    }

    // =====================================================================================
    // Minimal views — the derived figures live in CubitLens (bytecode size)
    // =====================================================================================

    function wallCount() external view returns (uint256) { return _walls.walls.length; }
    function activeWallCount() external view returns (uint256) { return _walls.active.length; }
    function activeWallId(uint256 index) external view returns (uint256) { return _walls.active[index]; }
    function latestWallId() external view returns (uint256) { return _walls.latestId; }
    /// @notice The active wall nearest to the market, the first a sale meets: the lowest active lower tick, so the
    ///         highest ETH price. `exists` is false when no wall stands.
    function nearestWallTick() external view returns (bool exists, int24 lower) {
        if (_walls.active.length == 0) return (false, 0);
        return (true, _walls.nearestTick);
    }
    function wallIdleEth() external view returns (uint256) { return _walls.idleEth; }
    function wallEstablished() public view returns (bool) { return _walls.walls.length != 0; }
    /// @notice Compatibility reference: the LAST funded wall, not a global minimum price.
    function wallTickLower() public view returns (int24) {
        return wallEstablished() ? _walls.walls[_walls.latestId].lower : int24(0);
    }
    function wallLiquidity() external view returns (uint128) {
        return wallEstablished() ? _walls.walls[_walls.latestId].liquidity : uint128(0);
    }
    function wallEthDeployed() external view returns (uint256 eth) {
        if (!wallEstablished()) return 0;
        WallLib.Wall storage w = _walls.walls[_walls.latestId];
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        (eth,) = BandLib.amountsForLiquidity(sqrtP, w.lower, w.lower + TICK_SPACING, w.liquidity);
    }
    function walls(uint256 id) external view returns (int24 lower, uint128 liquidity, uint256 idleEth, uint256 fundedEth) {
        WallLib.Wall storage w = _walls.walls[id];
        return (w.lower, w.liquidity, w.idleEth, w.fundedEth);
    }
    function wallAmounts(uint160 sqrtP) external view returns (uint256 eth, uint256 tokens) {
        return WallLib.amounts(_walls, sqrtP, TICK_SPACING);
    }

    /// @inheritdoc ICubitHook
    function band() external view returns (int24 lower, int24 upper, uint128 liquidity) {
        return (_band.lower, _band.upper, _band.liquidity);
    }

    /// @inheritdoc ICubitHook
    function absorbedTokenSink() public view returns (address) {
        if (v2 != address(0)) return ICubitV2(v2).vault();
        return ICubitForgeSink(token.deployer()).governanceVault();
    }
}
