// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @title ICubitHook — public surface of the CUBIT mechanism (dashboard, bots)
/// @notice Events are the content feed of the project; the views are what the Proof of Wall
///         dashboard reads. See CONTRACT_SPEC §5-§8.
interface ICubitHook {
    // ------------------------------------------------------------------ events (spec §7)
    /// @notice ETH tax base, zero wall allocation, and the 3% team allocation.
    /// @dev ethIn is specified gross input for exact-input buys, executed gross for exact-output buys.
    event BuyTaxed(uint256 ethIn, uint256 toFloor, uint256 toTeam);
    /// @notice ETH tax base and the 12%/3% split of the 15% sell tax.
    /// @dev Replaces SellTaxed(uint256,uint256); the legacy signature is never emitted.
    ///      ethOut is requested gross for exact-output sells, executed gross for exact-input sells.
    ///      The canonical router rejects partial fills; net = ethOut - toFloor - toTeam on full fills.
    ///      Rounding residual belongs to walls.
    event SellTaxed(uint256 ethOut, uint256 toFloor, uint256 toTeam);
    /// @notice A deposit at a fixed range; IDs and ticks never change. A later deposit may be lower.
    event WallFunded(uint256 indexed id, int24 indexed lower, uint256 addedEth, uint128 liquidity);
    /// @notice A fully crossed wall emptied: its CUBIT and the ETH it releases back to pending funds.
    event WallAbsorbed(uint256 indexed id, uint256 cubit, uint256 ethRemaining);
    event TokensBurned(uint256 amount, uint256 totalBurned);
    event TokensAbsorbed(uint256 amount, uint256 pendingAbsorbedTokens);
    /// @notice Absorbed CUBIT handed to their sink: the vault reward reserve, or a child's governance vault.
    event AbsorbedDelivered(address indexed sink, uint256 amount);
    event TeamPaid(uint256 amount, uint256 cumulative);
    /// @notice The single trading position, placed at initialization (ticks in pool orientation);
    ///         `tokens` is the CUBIT it holds.
    event BandBootstrapped(int24 lower, int24 upper, uint128 liquidity, uint256 tokens);

    // ------------------------------------------------------------------ errors (spec §8)
    error NotPoolManager();
    error ExternalLiquidityForbidden();
    error NotHookOwnedPool();
    error WallInRange();
    error AlreadyInitialized();
    error SupplyNotDeposited();
    error HookNotAuthorised();
    error Reentrancy();
    error HookNotImplemented();
    error UnexpectedInitialPrice();
    /// @dev The team address is immutable (I5): a zero here would be permanent.
    error ZeroAddress();

    // ------------------------------------------------------------------ public functions
    function deliverAbsorbed() external;
    function claimTeam() external;

    // ------------------------------------------------------------------ raw state
    function initialized() external view returns (bool);
    function poolManager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
    function pendingFloorEth() external view returns (uint256);
    function wallTickLower() external view returns (int24);
    function wallLiquidity() external view returns (uint128);
    function wallEstablished() external view returns (bool);
    function pendingAbsorbedTokens() external view returns (uint256);
    /// @notice Where absorbed CUBIT go: the registry's current vault, or, for a hook without a registry
    ///         (a Forge child), the governance vault of the Forge that deployed its token.
    function absorbedTokenSink() external view returns (address);
    function wallEthDeployed() external view returns (uint256);
    /// @notice The single trading position: [minUsableTick, opening tick floored to the spacing].
    function band() external view returns (int24 lower, int24 upper, uint128 liquidity);
    function MIN_POOL_SUPPLY() external view returns (uint256);
    function teamAccrued() external view returns (uint256);
    function teamPaidCumulative() external view returns (uint256);
    function TEAM_ADDRESS() external view returns (address);
    function TICK_SPACING() external view returns (int24);
    function POOL_FEE() external view returns (uint24);
    function WALL_RETRACEMENT_BPS() external view returns (uint256);
    function LAUNCH_ETH() external view returns (uint256);
    function INITIAL_SQRT_PRICE() external view returns (uint160);
    function wallCount() external view returns (uint256);
    function activeWallCount() external view returns (uint256);
    function activeWallId(uint256 index) external view returns (uint256);
    function latestWallId() external view returns (uint256);
    function wallIdleEth() external view returns (uint256);
    function MAX_ACTIVE_WALLS() external view returns (uint256);
    function walls(uint256 id) external view returns (int24 lower, uint128 liquidity, uint256 idleEth, uint256 fundedEth);
    function wallAmounts(uint160 sqrtPrice) external view returns (uint256 eth, uint256 tokens);
    function FLOOR_SALT() external view returns (bytes32);
    function BAND_SALT() external view returns (bytes32);
}
