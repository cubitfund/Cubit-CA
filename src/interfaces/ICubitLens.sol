// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

/// @title ICubitLens — derived, read-only figures for the Proof of Wall dashboard
/// @notice Everything here is computed from the hook's public state and the pool's slot0.
///         Prices are ETH per CUBIT, 1e18 fixed point (the specification orientation).
interface ICubitLens {
    struct Snapshot {
        // floor (the sacred book)
        uint256 floorPrice; // gross price at the top of the LATEST funded wall, which a later sale may have emptied
        uint256 netFloorPrice; // that wall's lower edge after LP fee, maximum protocol fee and sell tax
        uint256 pendingFloorEth; // wall funds not placed yet
        uint256 pendingAbsorbedTokens; // crossed-wall CUBIT awaiting delivery; add ONCE to the sum of wall pages
        uint256 totalSupply; // subtract wall CUBIT (including pending) and rewardReserve to derive circulation
        uint256 activeWallCount; // size of the active enumeration at this block
        uint256 rewardReserve; // CUBIT every registered vault still holds for future staking rewards
        uint256 totalBurned;
        int24 wallTickLower;
        uint128 wallLiquidity;
        // band (the trading book)
        uint256 bandEth; // ETH the band holds at the current price (principal, LP fees excluded)
        uint256 bandTokens; // CUBIT the band still offers
        // market
        uint256 marketPrice;
        int24 tick;
        // team
        uint256 teamAccrued;
        uint256 teamPaidCumulative;
        // block the snapshot was read at
        uint256 blockNumber;
        // holders and the standing walls
        uint256 bestWallPrice; // gross price at the top of the active wall nearest to the market, 0 when none stands
        uint256 netBestWallPrice; // that wall's lower edge after LP fee, maximum protocol fee and sell tax
    }

    /// @notice Reads no wall enumeration. Read wall pages at the SAME block as this snapshot.
    /// @dev wallTokens = sum(page.tokens) + pendingAbsorbedTokens;
    ///      circulatingSupply = max(totalSupply - wallTokens - rewardReserve, 0);
    ///      heldSupply = max(circulatingSupply - bandTokens, 0). Staked CUBIT remain held.
    function snapshot() external view returns (Snapshot memory);
    function activeWallCount() external view returns (uint256);
    /// @notice Principal of active walls in [start, start + count), clipped to the active enumeration.
    /// @dev Caller chooses count; there is no contract page limit. Excludes idle ETH, LP fees and pending CUBIT.
    ///      start >= total returns (0, 0, total, total); count == 0 does not advance.
    ///      next is the next active index, total the active count. Indices can move on removal:
    ///      ALL pages and the snapshot MUST use the same block, never separate `latest` reads.
    function wallAmountsPage(uint256 start, uint256 count)
        external view returns (uint256 eth, uint256 tokens, uint256 next, uint256 total);
    function floorPrice() external view returns (uint256);
    function netFloorPrice() external view returns (uint256);
    function bestWallPrice() external view returns (uint256);
    function netBestWallPrice() external view returns (uint256);
    function rewardReserve() external view returns (uint256);
    function bandEth() external view returns (uint256);
    function bandTokens() external view returns (uint256);
    function marketPrice() external view returns (uint256);
    function currentTick() external view returns (int24);
}
