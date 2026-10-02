// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LensReads} from "../../utils/LensReads.sol";

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {assertInvariant} from "../../utils/InvariantAssertions.sol";
import {CubitToken} from "../../../src/CubitToken.sol";
import {CubitHook} from "../../../src/CubitHook.sol";
import {CubitLens} from "../../../src/CubitLens.sol";
import {CubitRouter} from "../../../src/periphery/CubitRouter.sol";
import {CubitVault} from "../../../src/periphery/CubitVault.sol";
import {CubitV2} from "../../../src/periphery/CubitV2.sol";
import {BandLib} from "../../../src/libraries/BandLib.sol";

/// @notice Invariant handler for the redesigned release. Six actors trade in every mode through the canonical router
///         and through a route that neither delivers nor fills fully, deliver absorbed CUBIT, stake, withdraw, claim,
///         fund and donate to the vault, replace it, move time and try to add liquidity. Every action is revert-free:
///         a user-side refusal is caught and checked not to come from the hook. Per-action properties are asserted
///         here; the global ones are in `checkAll`.
contract RedesignHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MAX_VAULT_REPLACEMENTS = 3;

    IPoolManager public manager;
    CubitToken public token;
    CubitHook public hook;
    CubitLens public lens;
    CubitRouter public router;
    CubitV2 public registry;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public lpRouter;
    address public team;
    PoolKey internal key;
    PoolId internal poolId;

    address[] public actors;
    uint256 public ethUniverse;
    uint256 public burnedAtLaunch;
    uint256 public initialReserve;
    uint128 public bandLiquidity;

    // campaign evidence
    uint256 public calls;
    uint256 public buys;
    uint256 public sells;
    uint256 public rawTrades;
    uint256 public roundTrips;
    uint256 public userRefusals;
    uint256 public deliveries;
    uint256 public teamClaims;
    uint256 public stakes;
    uint256 public withdrawals;
    uint256 public rewardClaims;
    uint256 public fundings;
    uint256 public vaultReplacements;
    uint256 public wallsEmptied;
    uint256 public maxWallsEmptiedInOneAction;
    uint256 public maxActiveWalls;
    uint256 public maxPendingAfterSale;
    // Per-sequence coverage, including the initial tick and each completed action.
    int24 public maxTick;
    // Sale checks in the extension, skipped for a zero target, or limited by wall capacity.
    uint256 public salesInExtendedWatch;
    uint256 public salesOutsidePendingWatch;
    uint256 public salesAtWallCapacity;

    // ghosts
    uint256 public lastTeamTotal;
    uint256 public funded;
    uint256 public lastAbsorbedTotal;
    uint256 public knownWalls;
    mapping(uint256 => int24) public wallTick;
    mapping(uint256 => uint128) public wallLiquidity;

    constructor(
        IPoolManager manager_,
        CubitToken token_,
        CubitHook hook_,
        CubitLens lens_,
        CubitRouter router_,
        CubitV2 registry_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        address team_
    ) {
        manager = manager_;
        token = token_;
        hook = hook_;
        lens = lens_;
        router = router_;
        registry = registry_;
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        team = team_;
        key = hook_.poolKey();
        poolId = hook_.poolId();
        (, maxTick,,) = manager_.getSlot0(poolId);
        burnedAtLaunch = token_.totalBurned();
        initialReserve = CubitVault(registry_.vault()).rewardReserve();
        (,, bandLiquidity) = hook_.band();
        for (uint256 i; i < 6; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("redesign actor", i)))));
            actors.push(a);
            vm.deal(a, 5_000 ether);
        }
        ethUniverse = _ethUniverse();
    }

    modifier step() {
        calls++;
        _;
        _afterStep();
    }

    /// @dev For a harness that funds this handler after construction (Medusa checks a call's value against the
    ///      calling contract's balance): read the ETH universe again, once, before any action.
    function syncEthUniverse() external {
        require(calls == 0, "only before the first action");
        ethUniverse = _ethUniverse();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _currentVault() internal view returns (CubitVault) {
        return CubitVault(registry.vault());
    }

    function _anyVault(uint256 seed) internal view returns (CubitVault) {
        return CubitVault(registry.vaults(seed % registry.vaultCount()));
    }

    function _sqrtP() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(poolId);
    }

    function _cubitAt(uint256 eth, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(eth, sqrtP, Q96), sqrtP, Q96);
    }

    function _ethAt(uint256 cubit, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(cubit, Q96, sqrtP), Q96, sqrtP);
    }

    // ------------------------------------------------------------------ trades through the canonical router

    function buyExactIn(uint256 seed, uint256 eth) external step {
        address who = _actor(seed);
        eth = bound(eth, 1e9, 25 ether);
        if (who.balance < eth) return;
        uint160 sqrtBefore = _sqrtP();
        vm.prank(who);
        try router.swapExactIn{value: eth}(key, true, eth, 0, who, type(uint256).max) returns (uint256 out) {
            buys++;
            assertInvariant(out <= _cubitAt(eth, sqrtBefore) + 1, "ECON: a buy was filled above the spot");
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
    }

    function buyExactOut(uint256 seed, uint256 cubit) external step {
        address who = _actor(seed);
        cubit = bound(cubit, 1e12, 3_000_000e18);
        uint256 maxEth = who.balance > 100 ether ? 100 ether : who.balance;
        if (maxEth == 0) return;
        uint160 sqrtBefore = _sqrtP();
        vm.prank(who);
        try router.swapExactOut{value: maxEth}(key, true, cubit, maxEth, who, type(uint256).max) returns (uint256 gross) {
            buys++;
            assertInvariant(cubit <= _cubitAt(gross, sqrtBefore) + 1, "ECON: a buy was filled above the spot");
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
    }

    function sellExactIn(uint256 seed, uint256 bps) external step {
        address who = _actor(seed);
        uint256 amount = token.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        uint160 sqrtBefore = _sqrtP();
        vm.startPrank(who);
        token.approve(address(router), amount);
        try router.swapExactIn(key, false, amount, 0, who, type(uint256).max) returns (uint256 net) {
            sells++;
            assertInvariant(_cubitAt(net, sqrtBefore) <= amount + 1, "ECON: a sale was filled above the spot");
            _assertNoWallFundsPile();
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
        vm.stopPrank();
    }

    function sellExactOut(uint256 seed, uint256 bps) external step {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        if (balance == 0) return;
        uint160 sqrtBefore = _sqrtP();
        uint256 worth = _ethAt(balance, sqrtBefore);
        if (worth > 500 ether) worth = 500 ether;
        uint256 net = worth * bound(bps, 1, 3_000) / 10_000;
        if (net == 0) return;
        vm.startPrank(who);
        token.approve(address(router), balance);
        try router.swapExactOut(key, false, net, balance, who, type(uint256).max) returns (uint256 used) {
            sells++;
            assertInvariant(_cubitAt(net, sqrtBefore) <= used + 1, "ECON: a sale was filled above the spot");
            _assertNoWallFundsPile();
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
        vm.stopPrank();
    }

    /// @dev Buy, then sell exactly what was bought: never more ETH back than was paid.
    function roundTrip(uint256 seed, uint256 eth) external step {
        address who = _actor(seed);
        eth = bound(eth, 1e12, 10 ether);
        if (who.balance < eth) return;
        vm.prank(who);
        try router.swapExactIn{value: eth}(key, true, eth, 0, who, type(uint256).max) returns (uint256 out) {
            vm.startPrank(who);
            token.approve(address(router), out);
            try router.swapExactIn(key, false, out, 0, who, type(uint256).max) returns (uint256 back) {
                roundTrips++;
                assertInvariant(back <= eth, "ECON: a round trip returned more ETH than it cost");
                _assertNoWallFundsPile();
            } catch (bytes memory reason) {
                _userRefusal(reason);
            }
            vm.stopPrank();
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
    }

    // ------------------------------------------------------------------ a route that does not deliver

    /// @dev A price-limited sale: it can stop inside a wall, cross many walls, or run past the band's top.
    function rawSell(uint256 seed, uint256 bps, uint256 ticks) external step {
        address who = _actor(seed);
        uint256 amount = token.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        (uint160 sqrtBefore, int24 tick,,) = manager.getSlot0(poolId);
        int256 limitTick = int256(tick) + int256(bound(ticks, 1, 40_000));
        if (limitTick >= TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK - 1;
        if (limitTick <= tick) return;
        vm.startPrank(who);
        token.approve(address(swapRouter), amount);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(int24(limitTick))
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (BalanceDelta d) {
            rawTrades++;
            uint256 used = d.amount1() < 0 ? uint256(uint128(-d.amount1())) : 0;
            uint256 net = d.amount0() > 0 ? uint256(uint128(d.amount0())) : 0;
            assertInvariant(used <= amount, "raw sale took more CUBIT than specified");
            assertInvariant(_cubitAt(net, sqrtBefore) <= used + 1, "ECON: a raw sale was filled above the spot");
            _assertNoWallFundsPile();
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
        vm.stopPrank();
    }

    function rawBuy(uint256 seed, uint256 eth) external step {
        address who = _actor(seed);
        eth = bound(eth, 1e9, 20 ether);
        if (who.balance < eth) return;
        uint160 sqrtBefore = _sqrtP();
        vm.prank(who);
        try swapRouter.swap{value: eth}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (BalanceDelta d) {
            rawTrades++;
            uint256 paid = d.amount0() < 0 ? uint256(uint128(-d.amount0())) : 0;
            uint256 out = d.amount1() > 0 ? uint256(uint128(d.amount1())) : 0;
            assertInvariant(out <= _cubitAt(paid, sqrtBefore) + 1, "ECON: a raw buy was filled above the spot");
        } catch (bytes memory reason) {
            _userRefusal(reason);
        }
    }

    // ------------------------------------------------------------------ public functions of the hook

    function deliverAbsorbed(uint256 seed) external step {
        CubitVault sink = _currentVault();
        uint256 pending = hook.pendingAbsorbedTokens();
        uint256 reserve0 = sink.rewardReserve();
        vm.prank(_actor(seed));
        hook.deliverAbsorbed();
        deliveries++;
        assertInvariant(hook.pendingAbsorbedTokens() == 0, "delivery left absorbed CUBIT behind");
        assertInvariant(sink.rewardReserve() - reserve0 == pending, "delivery did not reach the current vault reserve");
    }

    function claimTeam(uint256 seed) external step {
        uint256 accrued = hook.teamAccrued();
        uint256 balance0 = team.balance;
        vm.prank(_actor(seed));
        hook.claimTeam();
        teamClaims++;
        assertInvariant(team.balance - balance0 == accrued, "claimTeam paid a different amount");
        assertInvariant(hook.teamAccrued() == 0, "claimTeam left an accrued share");
    }

    // ------------------------------------------------------------------ vault

    function stake(uint256 seed, uint256 bps) external step {
        address who = _actor(seed);
        CubitVault v = _currentVault();
        if (registry.enabledFeatures() & 1 == 0) return;
        uint256 amount = token.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        uint256 staked0 = v.balanceOf(who);
        vm.startPrank(who);
        token.approve(address(v), amount);
        v.stake(amount);
        vm.stopPrank();
        stakes++;
        assertInvariant(v.balanceOf(who) == staked0 + amount, "stake not booked");
    }

    function withdraw(uint256 seed, uint256 vaultSeed, uint256 bps) external step {
        address who = _actor(seed);
        CubitVault v = _anyVault(vaultSeed);
        uint256 staked = v.balanceOf(who);
        uint256 amount = staked * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        uint256 due = v.pendingCubit(who);
        uint256 balance0 = token.balanceOf(who);
        // Read before the prank: an external read would consume it and send the call from this handler.
        bool locked = block.timestamp < v.unlockAt(who);
        vm.prank(who);
        if (locked) {
            try v.withdraw(amount) {
                assertInvariant(false, "a locked stake was withdrawn");
            } catch (bytes memory reason) {
                assertInvariant(bytes4(reason) == CubitVault.Locked.selector, "locked withdraw refused for another reason");
            }
            return;
        }
        v.withdraw(amount);
        withdrawals++;
        assertInvariant(token.balanceOf(who) - balance0 == amount + due, "withdraw paid a different amount");
        assertInvariant(v.balanceOf(who) == staked - amount, "withdraw not booked");
    }

    function claimCubit(uint256 seed, uint256 vaultSeed) external step {
        address who = _actor(seed);
        CubitVault v = _anyVault(vaultSeed);
        uint256 due = v.pendingCubit(who);
        uint256 cap = v.balanceOf(who) * 300 / 10_000;
        uint256 reserve0 = v.rewardReserve();
        uint256 balance0 = token.balanceOf(who);
        vm.prank(who);
        v.claimCubit();
        rewardClaims++;
        assertInvariant(due <= cap, "a reward exceeded 3% of the stake");
        assertInvariant(token.balanceOf(who) - balance0 == due, "claim paid a different amount");
        assertInvariant(reserve0 - v.rewardReserve() == due, "claim not paid from the reserve");
    }

    function fundReserve(uint256 seed, uint256 bps) external step {
        address who = _actor(seed);
        CubitVault v = _currentVault();
        uint256 amount = token.balanceOf(who) * bound(bps, 1, 2_000) / 10_000;
        if (amount == 0) return;
        vm.startPrank(who);
        token.approve(address(v), amount);
        v.fundRewardReserve(amount);
        vm.stopPrank();
        funded += amount;
        fundings++;
    }

    /// @dev A plain transfer is not booked: the vault must stay solvent with unbooked tokens on top.
    function donateToVault(uint256 seed, uint256 bps) external step {
        address who = _actor(seed);
        uint256 amount = token.balanceOf(who) * bound(bps, 1, 500) / 10_000;
        if (amount == 0) return;
        address sink = address(_currentVault());
        vm.prank(who);
        token.transfer(sink, amount);
    }

    function replaceVault() external step {
        if (vaultReplacements >= MAX_VAULT_REPLACEMENTS) return;
        CubitVault next = new CubitVault(hook);
        vm.startPrank(team);
        registry.setVault(address(next));
        registry.activate(1);
        vm.stopPrank();
        vaultReplacements++;
    }

    // ------------------------------------------------------------------ time and outsiders

    function warp(uint256 secs) external step {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function externalLiquidity(uint256 seed, int256 offset) external step {
        address who = _actor(seed);
        int24 spacing = hook.TICK_SPACING();
        (, int24 tick,,) = manager.getSlot0(poolId);
        int256 lower = (int256(tick) + bound(offset, -5_000, 5_000)) / spacing * spacing - 5 * spacing;
        int256 upper = lower + 10 * spacing;
        if (lower < TickMath.minUsableTick(spacing) || upper > TickMath.maxUsableTick(spacing)) return;
        vm.startPrank(who);
        token.approve(address(lpRouter), type(uint256).max);
        try lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: int24(lower), tickUpper: int24(upper), liquidityDelta: 1e9, salt: bytes32(seed)
            }),
            ""
        ) {
            assertInvariant(false, "external liquidity was accepted");
        } catch {}
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ checks

    function _userRefusal(bytes memory reason) internal {
        bytes4 sel = bytes4(reason);
        if (sel == CustomRevert.WrappedError.selector) {
            bytes memory tail = new bytes(reason.length - 4);
            for (uint256 i; i < tail.length; i++) {
                tail[i] = reason[i + 4];
            }
            (address target,,,) = abi.decode(tail, (address, bytes4, bytes, bytes));
            if (target == address(hook)) {
                console2.logBytes(reason);
                assertInvariant(false, "the hook reverted a trade");
            }
        } else if (
            sel == Hooks.HookDeltaExceedsSwapAmount.selector || sel == Hooks.InvalidHookResponse.selector
                || sel == Hooks.HookCallFailed.selector || sel == IPoolManager.CurrencyNotSettled.selector
        ) {
            console2.logBytes(reason);
            assertInvariant(false, "a hook-induced trade failure");
        }
        userRefusals++;
    }

    /// @dev Check placement while BandLib's rounded WAD price is >= 2, so its 99% target is nonzero.
    ///      The transition lies INSIDE tick 407,554; the tick alone cannot classify that whole interval.
    ///      Keep the global pending maximum even on skipped sales. In the extension starting at tick 400,000,
    ///      require zero dust; retain the historical 1e9-wei tolerance below it. Excess funds may wait only
    ///      when the intended wall has reached the hook's liquidity cap. A nonzero target alone is not enough.
    function _assertNoWallFundsPile() internal {
        uint256 pending = hook.pendingFloorEth();
        if (pending > maxPendingAfterSale) maxPendingAfterSale = pending;
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        if (BandLib.ethPerCubitAtSqrt(sqrtP) < 2) {
            salesOutsidePendingWatch++;
            return;
        }
        if (tick >= 400_000) salesInExtendedWatch++;
        if (pending <= (tick >= 400_000 ? 0 : 1e9)) return;

        int24 spacing = hook.TICK_SPACING();
        int24 target = BandLib.retracementWallTarget(hook.INITIAL_SQRT_PRICE(), sqrtP, spacing);
        if (tick >= target) target = BandLib.underMarketWallTarget(sqrtP, spacing);
        uint128 cap = hook.MAX_LIQUIDITY_PER_TICK();
        uint256 active = hook.activeWallCount();
        for (uint256 i; i < active; i++) {
            (int24 lower, uint128 liquidity,,) = hook.walls(hook.activeWallId(i));
            if (lower == target && liquidity == cap) {
                salesAtWallCapacity++;
                return;
            }
        }
        assertInvariant(false, "wall funds piled up without saturating the target wall");
    }

    function _afterStep() internal {
        (, int24 tick,,) = manager.getSlot0(poolId);
        if (tick > maxTick) maxTick = tick;

        uint256 teamTotal = hook.teamAccrued() + hook.teamPaidCumulative();
        assertInvariant(teamTotal >= lastTeamTotal, "the team entitlement decreased");
        lastTeamTotal = teamTotal;

        uint256 absorbed = _absorbedTotal();
        assertInvariant(absorbed >= lastAbsorbedTotal, "absorbed CUBIT left without being paid as rewards");
        lastAbsorbedTotal = absorbed;

        uint256 count = hook.wallCount();
        assertInvariant(count >= knownWalls, "wall history was deleted");
        uint256 emptied;
        for (uint256 id; id < count; id++) {
            (int24 lower, uint128 liquidity,,) = hook.walls(id);
            if (id < knownWalls) {
                assertInvariant(lower == wallTick[id], "a wall moved");
                uint128 before = wallLiquidity[id];
                assertInvariant(liquidity >= before || liquidity == 0, "a wall was partially withdrawn");
                if (before != 0 && liquidity == 0) emptied++;
            } else {
                wallTick[id] = lower;
            }
            wallLiquidity[id] = liquidity;
        }
        knownWalls = count;
        wallsEmptied += emptied;
        if (emptied > maxWallsEmptiedInOneAction) maxWallsEmptiedInOneAction = emptied;
        uint256 active = hook.activeWallCount();
        if (active > maxActiveWalls) maxActiveWalls = active;
    }

    /// @dev Pending absorbed CUBIT plus every reserve and every reward paid, minus what launch and funding put in: this
    ///      can only grow, and only because crossed walls absorbed CUBIT.
    function _absorbedTotal() internal view returns (uint256 total) {
        total = hook.pendingAbsorbedTokens();
        uint256 n = registry.vaultCount();
        for (uint256 i; i < n; i++) {
            CubitVault v = CubitVault(registry.vaults(i));
            total += v.rewardReserve() + v.totalCubitPaid();
        }
        assertInvariant(total >= initialReserve + funded, "reserves hold less than launch and funding put in");
        total -= initialReserve + funded;
    }

    function _ethUniverse() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; i++) {
            sum += actors[i].balance;
        }
        sum += address(manager).balance + team.balance + address(router).balance + address(swapRouter).balance
            + address(lpRouter).balance + address(this).balance;
    }

    function checkBooksAndSupply() public view {
        assertInvariant(
            manager.balanceOf(address(hook), 0)
                == hook.pendingFloorEth() + hook.teamAccrued() + hook.wallIdleEth(),
            "ETH claims differ from the books"
        );
        assertInvariant(
            manager.balanceOf(address(hook), uint256(uint160(address(token)))) == hook.pendingAbsorbedTokens(),
            "CUBIT claims differ from the absorbed queue"
        );
        assertInvariant(token.balanceOf(address(hook)) == 0, "the hook holds raw CUBIT");
        assertInvariant(address(hook).balance == 0, "the hook holds raw ETH");
        assertInvariant(token.totalSupply() + token.totalBurned() == token.TOTAL_SUPPLY(), "supply accounting");
        assertInvariant(token.totalBurned() == burnedAtLaunch, "CUBIT burned after launch");
    }

    function checkEth() public view {
        assertInvariant(_ethUniverse() == ethUniverse, "ETH created or destroyed");
        assertInvariant(team.balance == hook.teamPaidCumulative(), "the team received ETH outside claimTeam");
    }

    function checkWallsAndBand() public view {
        int24 spacing = hook.TICK_SPACING();
        (, int24 tick,,) = manager.getSlot0(poolId);
        uint256 count = hook.wallCount();
        uint256 live = hook.activeWallCount();
        bool[] memory active = new bool[](count);
        for (uint256 i; i < live; i++) {
            uint256 id = hook.activeWallId(i);
            assertInvariant(id < count && !active[id], "duplicate or invalid active wall");
            active[id] = true;
        }
        uint256 idle;
        int24 lowest = type(int24).max;
        for (uint256 id; id < count; id++) {
            (int24 lower, uint128 liquidity, uint256 earmarked,) = hook.walls(id);
            assertInvariant((liquidity != 0) == active[id], "a wall's liquidity disagrees with the active index");
            assertInvariant(lower % spacing == 0, "misaligned wall");
            if (liquidity != 0) {
                if (lower < lowest) lowest = lower;
                assertInvariant(tick < lower + spacing, "a fully crossed wall was left in place");
                (uint128 recorded,,) =
                    manager.getPositionInfo(poolId, address(hook), lower, lower + spacing, hook.FLOOR_SALT());
                assertInvariant(recorded == liquidity, "wall liquidity differs from the PoolManager");
            }
            idle += earmarked;
        }
        assertInvariant(idle == hook.wallIdleEth(), "earmarked wall ETH does not reconcile");
        (bool standing, int24 nearest) = hook.nearestWallTick();
        assertInvariant(standing == (live != 0), "the nearest-wall view disagrees with the active walls");
        if (standing) assertInvariant(nearest == lowest, "the nearest wall is not the lowest active tick");
        (int24 bandLower, int24 bandUpper, uint128 bandLiq) = hook.band();
        (uint128 recordedBand,,) = manager.getPositionInfo(poolId, address(hook), bandLower, bandUpper, hook.BAND_SALT());
        assertInvariant(bandLiq == bandLiquidity && recordedBand == bandLiquidity, "the band changed");
    }

    function checkVaultsAndLens() public view {
        uint256 reserves;
        uint256 n = registry.vaultCount();
        for (uint256 i; i < n; i++) {
            CubitVault v = CubitVault(registry.vaults(i));
            assertInvariant(
                token.balanceOf(address(v)) >= v.totalStaked() + v.rewardReserve(), "a vault is insolvent"
            );
            reserves += v.rewardReserve();
        }
        assertInvariant(lens.rewardReserve() == reserves, "the Lens reserve differs from the vaults");
        assertInvariant(
            LensReads.circulatingSupply(lens) == token.totalSupply() - LensReads.wallTokens(lens) - reserves,
            "the Lens circulating supply is wrong"
        );
        uint256 circulating = LensReads.circulatingSupply(lens);
        uint256 band = lens.bandTokens();
        assertInvariant(LensReads.heldSupply(lens) == (circulating > band ? circulating - band : 0), "the Lens held supply is wrong");
        (bool standing, int24 nearest) = hook.nearestWallTick();
        assertInvariant(
            lens.bestWallPrice() == (standing ? BandLib.ethPerCubitAtTick(nearest) : 0), "the Lens best wall is wrong"
        );
    }

    function checkAll() external view {
        checkBooksAndSupply();
        checkEth();
        checkWallsAndBand();
        checkVaultsAndLens();
    }
}
