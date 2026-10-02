// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title ICubitQuoteHook — public surface of a launchpad v2 child hook
/// @notice The CUBIT mechanism with any quote currency: native ETH, or an ERC-20 (USDC, USDT, WBTC, a tokenized stock).
///         Every amount named `quote` is in the quote's own base units. The events keep the signatures of ICubitHook,
///         so one reader follows the taxes and walls of every child, whatever its launchpad.
interface ICubitQuoteHook {
    // ------------------------------------------------------------------ events
    /// @notice Quote tax base, zero wall allocation, and the team allocation (the whole buy tax).
    event BuyTaxed(uint256 quoteIn, uint256 toFloor, uint256 toTeam);
    /// @notice Quote tax base and the walls/team split of the sell tax.
    event SellTaxed(uint256 quoteOut, uint256 toFloor, uint256 toTeam);
    /// @notice A deposit at a fixed range; IDs and ticks never change. A later deposit may be lower.
    event WallFunded(uint256 indexed id, int24 indexed lower, uint256 addedQuote, uint128 liquidity);
    /// @notice A fully crossed wall emptied: its child tokens and the quote it releases back to pending funds.
    event WallAbsorbed(uint256 indexed id, uint256 tokens, uint256 quoteRemaining);
    event TokensBurned(uint256 amount, uint256 totalBurned);
    event TokensAbsorbed(uint256 amount, uint256 pendingAbsorbedTokens);
    /// @notice Absorbed child tokens handed to the launchpad governance vault.
    event AbsorbedDelivered(address indexed sink, uint256 amount);
    event TeamPaid(uint256 amount, uint256 cumulative);
    /// @notice The single trading position, placed at initialization (ticks in pool orientation).
    event BandBootstrapped(int24 lower, int24 upper, uint128 liquidity, uint256 tokens);

    // ------------------------------------------------------------------ errors
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
    error ZeroAddress();
    /// @dev The quote must sort before the token, so that it is the pool's currency0.
    error QuoteNotCurrency0();
    /// @dev A tax rate outside QuoteTaxes' bounds.
    error InvalidTaxes();

    // ------------------------------------------------------------------ public functions
    function deliverAbsorbed() external;
    function claimTeam() external;

    // ------------------------------------------------------------------ state
    function initialized() external view returns (bool);
    function poolManager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
    /// @notice The quote currency, the pool's currency0: address zero for native ETH.
    function quote() external view returns (Currency);
    /// @notice Launch FDV in quote base units, frozen at deployment.
    function LAUNCH_QUOTE() external view returns (uint256);
    /// @notice Tax rates chosen at launch, in basis points: buys (all to the team), and sales (walls + team).
    function BUY_TAX_BPS() external view returns (uint256);
    function SELL_TAX_BPS() external view returns (uint256);
    function SELL_FLOOR_BPS() external view returns (uint256);
    function SELL_TEAM_BPS() external view returns (uint256);
    function INITIAL_SQRT_PRICE() external view returns (uint160);
    function pendingFloorQuote() external view returns (uint256);
    function pendingAbsorbedTokens() external view returns (uint256);
    function absorbedTokenSink() external view returns (address);
    function band() external view returns (int24 lower, int24 upper, uint128 liquidity);
    function teamAccrued() external view returns (uint256);
    function teamPaidCumulative() external view returns (uint256);
    function TEAM_ADDRESS() external view returns (address);
    function wallCount() external view returns (uint256);
    function activeWallCount() external view returns (uint256);
    function activeWallId(uint256 index) external view returns (uint256);
    function latestWallId() external view returns (uint256);
    function nearestWallTick() external view returns (bool exists, int24 lower);
    function wallIdleQuote() external view returns (uint256);
    function walls(uint256 id)
        external view returns (int24 lower, uint128 liquidity, uint256 idleQuote, uint256 fundedQuote);
    function wallAmounts(uint160 sqrtPrice) external view returns (uint256 quoteAmount, uint256 tokens);
}
