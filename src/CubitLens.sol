// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

import {ICubitLens} from "./interfaces/ICubitLens.sol";
import {ICubitV2, ICubitVault} from "./interfaces/ICubitV2.sol";
import {CubitHook} from "./CubitHook.sol";
import {CubitToken} from "./CubitToken.sol";
import {BandLib} from "./libraries/BandLib.sol";

/// @title CubitLens — read-only derivations of the CUBIT state
/// @notice Stateless helper deployed next to the hook. Holds no funds, has no permissions;
///         redeployable at will without touching the mechanism.
contract CubitLens is ICubitLens {
    using StateLibrary for IPoolManager;

    CubitHook public immutable hook;
    IPoolManager public immutable poolManager;
    CubitToken public immutable token;
    PoolId public immutable poolId;
    int24 public immutable spacing;

    constructor(CubitHook hook_) {
        hook = hook_;
        poolManager = hook_.poolManager();
        token = hook_.token();
        poolId = hook_.poolId();
        spacing = hook_.TICK_SPACING();
    }

    function _slot0() internal view returns (uint160 sqrtP, int24 tick) {
        (sqrtP, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @inheritdoc ICubitLens
    function floorPrice() public view returns (uint256) {
        if (!hook.wallEstablished()) return 0;
        return BandLib.ethPerCubitAtTick(hook.wallTickLower());
    }

    /// @inheritdoc ICubitLens
    function netFloorPrice() public view returns (uint256) {
        if (!hook.wallEstablished()) return 0;
        return _netSalePrice(hook.wallTickLower() + spacing);
    }

    /// @inheritdoc ICubitLens
    function bestWallPrice() public view returns (uint256) {
        (bool exists, int24 lower) = hook.nearestWallTick();
        return exists ? BandLib.ethPerCubitAtTick(lower) : 0;
    }

    /// @inheritdoc ICubitLens
    function netBestWallPrice() public view returns (uint256) {
        (bool exists, int24 lower) = hook.nearestWallTick();
        return exists ? _netSalePrice(lower + spacing) : 0;
    }

    /// @dev Conservative sale price at `tick`, the lowest price of a wall range: after LP fees, the maximum possible
    ///      v4 protocol fee and the hook's sell tax. Budgeting the maximum protocol fee keeps the reference monotone if
    ///      governance changes it. A real quote is still needed for integer rounding, available depth and gas.
    function _netSalePrice(int24 tick) internal view returns (uint256) {
        uint256 gross = BandLib.ethPerCubitAtTick(tick);
        uint24 fee = ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.MAX_PROTOCOL_FEE, hook.POOL_FEE());
        uint256 afterPoolFees = FullMath.mulDiv(gross, 1_000_000 - fee, 1_000_000);
        return FullMath.mulDiv(afterPoolFees, hook.BPS() - hook.SELL_TAX_BPS(), hook.BPS());
    }

    /// @inheritdoc ICubitLens
    function activeWallCount() public view returns (uint256) {
        return hook.activeWallCount();
    }

    /// @inheritdoc ICubitLens
    function wallAmountsPage(uint256 start, uint256 count)
        external view returns (uint256 eth, uint256 tokens, uint256 next, uint256 total)
    {
        total = activeWallCount();
        if (start >= total) return (0, 0, total, total);
        // Subtract before adding: even count == type(uint256).max cannot overflow.
        uint256 remaining = total - start;
        next = start + (count < remaining ? count : remaining);
        if (next == start) return (0, 0, next, total);
        (uint160 sqrtP,) = _slot0();
        for (uint256 i = start; i < next; i++) {
            (int24 lower, uint128 liquidity,,) = hook.walls(hook.activeWallId(i));
            (uint256 a0, uint256 a1) = BandLib.amountsForLiquidity(sqrtP, lower, lower + spacing, liquidity);
            eth += a0;
            tokens += a1;
        }
    }

    /// @inheritdoc ICubitLens
    /// @dev Sums every registered vault, current and retired: a retired vault still pays its stakers from its
    ///      own reserve. A hook without a registry (a Forge child) has no vault. A registered vault that reverts counts
    ///      for nothing and one that over-reports counts at most the CUBIT it holds, so no module can break a read.
    function rewardReserve() public view returns (uint256 reserve) {
        address registry = hook.v2();
        if (registry == address(0)) return 0;
        uint256 count = ICubitV2(registry).vaultCount();
        for (uint256 i; i < count; i++) {
            address vault = ICubitV2(registry).vaults(i);
            try ICubitVault(vault).rewardReserve() returns (uint256 booked) {
                uint256 holding = token.balanceOf(vault);
                reserve += booked < holding ? booked : holding;
            } catch {}
        }
    }

    /// @dev Principal only: LP fees accrued inside the band are neither collected nor counted.
    function _bandAmounts(uint160 sqrtP) internal view returns (uint256 eth, uint256 tokens) {
        (int24 lower, int24 upper, uint128 liquidity) = hook.band();
        return BandLib.amountsForLiquidity(sqrtP, lower, upper, liquidity);
    }

    /// @inheritdoc ICubitLens
    function bandEth() public view returns (uint256 eth) {
        (uint160 sqrtP,) = _slot0();
        (eth,) = _bandAmounts(sqrtP);
    }

    /// @inheritdoc ICubitLens
    function bandTokens() public view returns (uint256 tokens) {
        (uint160 sqrtP,) = _slot0();
        (, tokens) = _bandAmounts(sqrtP);
    }

    /// @inheritdoc ICubitLens
    function marketPrice() public view returns (uint256) {
        (uint160 sqrtP,) = _slot0();
        return BandLib.ethPerCubitAtSqrt(sqrtP);
    }

    /// @inheritdoc ICubitLens
    function currentTick() public view returns (int24 tick) {
        (, tick) = _slot0();
    }

    /// @inheritdoc ICubitLens
    /// @dev Split into helpers that write through the same memory struct. One flat body
    ///      assigning every field keeps too many live locals: the Certora Prover instruments each
    ///      one to expose it to the specs, and that instrumented build hit "stack too deep" and
    ///      silently fell back to an uninstrumented file — the specs then could not see inside
    ///      this function at all. Splitting restores the instrumented build; `s` is passed by
    ///      memory reference, so the reads and the result are unchanged.
    function snapshot() external view returns (Snapshot memory s) {
        (uint160 sqrtP, int24 tick) = _slot0();
        s.tick = tick;
        s.marketPrice = BandLib.ethPerCubitAtSqrt(sqrtP);
        s.blockNumber = block.number;
        _snapshotFloor(s);
        _snapshotBand(s, sqrtP);
        _snapshotStatus(s);
        _snapshotHolders(s);
    }

    /// @dev The sacred book: the walls, what they hold, and what has been burned.
    function _snapshotFloor(Snapshot memory s) internal view {
        s.floorPrice = floorPrice();
        s.netFloorPrice = netFloorPrice();
        s.pendingAbsorbedTokens = hook.pendingAbsorbedTokens();
        s.totalSupply = token.totalSupply();
        s.activeWallCount = activeWallCount();
        s.pendingFloorEth = hook.pendingFloorEth();
        s.totalBurned = token.totalBurned();
        s.rewardReserve = rewardReserve();
        s.wallTickLower = hook.wallTickLower();
        s.wallLiquidity = hook.wallLiquidity();
    }

    /// @dev The trading book: what the band holds at the current price.
    function _snapshotBand(Snapshot memory s, uint160 sqrtP) internal view {
        (s.bandEth, s.bandTokens) = _bandAmounts(sqrtP);
    }

    /// @dev Accounts.
    function _snapshotStatus(Snapshot memory s) internal view {
        s.teamAccrued = hook.teamAccrued();
        s.teamPaidCumulative = hook.teamPaidCumulative();
    }

    /// @dev Holders and the standing walls, from the figures already read.
    function _snapshotHolders(Snapshot memory s) internal view {
        s.bestWallPrice = bestWallPrice();
        s.netBestWallPrice = netBestWallPrice();
    }

}
