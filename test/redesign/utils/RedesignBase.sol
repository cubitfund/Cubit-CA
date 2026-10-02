// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {CubitToken} from "../../../src/CubitToken.sol";
import {CubitHook} from "../../../src/CubitHook.sol";
import {CubitLens} from "../../../src/CubitLens.sol";
import {CubitRouter} from "../../../src/periphery/CubitRouter.sol";
import {CubitVault} from "../../../src/periphery/CubitVault.sol";
import {CubitV2} from "../../../src/periphery/CubitV2.sol";
import {CubitForge} from "../../../src/periphery/CubitForge.sol";
import {CubitLaunch} from "../../../src/periphery/CubitLaunch.sol";
import {CubitGovernanceVault} from "../../../src/periphery/CubitGovernanceVault.sol";
import {BandLib} from "../../../src/libraries/BandLib.sol";

/// @notice The redesigned release, wired like `DeployBase`: token, CREATE2 hook, peripherals and registry, then the
///         atomic launch (80% in the band, 20% in the vault reserve, optional taxed dev buy). The clock is a literal:
///         under via_ir a local copy of block.timestamp is re-read after vm.warp.
abstract contract RedesignBase is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant LAUNCH_ETH = 3.75 ether;
    uint256 internal constant START = 1_000_000;
    uint256 internal constant RESERVE = 4_200_000e18;
    uint256 internal constant Q96 = 1 << 96;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    CubitToken internal token;
    CubitHook internal hook;
    CubitLens internal lens;
    CubitRouter internal router;
    CubitVault internal vault;
    CubitGovernanceVault internal governanceVault;
    CubitForge internal forge;
    CubitV2 internal registry;
    CubitLaunch internal launcher;
    PoolKey internal key;
    PoolId internal poolId;

    address internal team = makeAddr("team");

    function setUp() public virtual {
        manager = _poolManager();
        vm.warp(START);
        swapRouter = new PoolSwapTest(manager);
        token = new CubitToken();
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), FLAGS, type(CubitHook).creationCode, abi.encode(manager, token, team, LAUNCH_ETH)
        );
        hook = new CubitHook{salt: salt}(manager, token, team, LAUNCH_ETH);
        require(address(hook) == predicted, "hook address mismatch");
        lens = new CubitLens(hook);
        router = new CubitRouter(manager, hook);
        vault = new CubitVault(hook);
        // As in production, no launchpad at launch: `_deployLaunchpad` adds it when a test needs it.
        registry = new CubitV2(hook, address(vault), address(router), address(0), address(lens));
        hook.configureV2(address(registry));
        launcher = new CubitLaunch(hook, router);
        token.setHook(address(hook));
        token.approve(address(launcher), token.TOTAL_SUPPLY());
        key = hook.poolKey();
        poolId = hook.poolId();
        vm.label(address(hook), "CubitHook");
        vm.label(address(token), "CUBIT");
        vm.label(address(manager), "PoolManager");
        vm.label(address(vault), "CubitVault");
        if (_launchInSetUp()) _launch(0);
    }

    function _launchInSetUp() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev The PoolManager the release is deployed against: a fresh one here, the canonical one in the fork suites
    ///      (audit/fork-redesign). The clock is set after it because selecting a fork resets the clock.
    function _poolManager() internal virtual returns (IPoolManager) {
        return new PoolManager(address(0));
    }

    /// @dev A fork pinned at FORK_BLOCK and the canonical PoolManager there. RPC reads only: every transaction, balance
    ///      and clock change stays in the local fork.
    function _forkedPoolManager(string memory rpcVariable, address canonical) internal returns (IPoolManager) {
        vm.createSelectFork(vm.envString(rpcVariable), vm.envUint("FORK_BLOCK"));
        require(canonical.code.length != 0, "no PoolManager at the canonical address");
        return IPoolManager(canonical);
    }

    /// @dev The one launch transaction. A dev buy needs a positive minimum, so it asks for at least 1 wei.
    function _launch(uint256 devBuyWei) internal returns (uint256 bought) {
        bought = launcher.launch{value: devBuyWei}(devBuyWei == 0 ? 0 : 1);
    }

    /// @dev The launchpad module, added after the launch as in production: the governance vault (this contract is its
    ///      deployer), the public Forge, and its registration by the team. Activation stays a separate step.
    function _deployLaunchpad() internal {
        governanceVault = new CubitGovernanceVault();
        forge = new CubitForge(hook, 0.01 ether, address(governanceVault));
        vm.prank(team);
        registry.setForge(address(forge));
    }

    /// @dev The launcher forwards the router's refund to the deployer.
    receive() external payable {}

    // ------------------------------------------------------------------ trades through the canonical router

    function _buy(address who, uint256 ethIn) internal returns (uint256 cubitOut) {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        cubitOut = router.swapExactIn{value: ethIn}(key, true, ethIn, 0, who, type(uint256).max);
    }

    function _buyExactOut(address who, uint256 cubitOut, uint256 maxEth) internal returns (uint256 ethIn) {
        vm.deal(who, who.balance + maxEth);
        vm.prank(who);
        ethIn = router.swapExactOut{value: maxEth}(key, true, cubitOut, maxEth, who, type(uint256).max);
    }

    function _sell(address who, uint256 cubitIn) internal returns (uint256 ethOut) {
        vm.startPrank(who);
        token.approve(address(router), cubitIn);
        ethOut = router.swapExactIn(key, false, cubitIn, 0, who, type(uint256).max);
        vm.stopPrank();
    }

    function _sellExactOut(address who, uint256 ethOut, uint256 maxCubit) internal returns (uint256 cubitIn) {
        vm.startPrank(who);
        token.approve(address(router), maxCubit);
        cubitIn = router.swapExactOut(key, false, ethOut, maxCubit, who, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A sale through a route that does not deliver the absorbed CUBIT, stopped at `limit` (partial fills allowed).
    function _rawSell(address who, uint256 cubitIn, uint160 limit) internal returns (uint256 used, uint256 ethOut) {
        vm.startPrank(who);
        token.approve(address(swapRouter), cubitIn);
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(cubitIn), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        used = d.amount1() < 0 ? uint256(uint128(-d.amount1())) : 0;
        ethOut = d.amount0() > 0 ? uint256(uint128(d.amount0())) : 0;
    }

    /// @dev CUBIT from outside the pool, taken out of the vault reserve: it stands in for rewards already paid out.
    function _giveReserveCubit(address who, uint256 amount) internal {
        vm.prank(address(vault));
        token.transfer(who, amount);
    }

    // ------------------------------------------------------------------ state helpers

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    function _sqrtP() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(poolId);
    }

    /// @dev CUBIT worth of `eth` at the pool price `sqrtP` (CUBIT per ETH = sqrtP² / 2^192), rounded down.
    function _cubitAt(uint256 eth, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(eth, sqrtP, Q96), sqrtP, Q96);
    }

    /// @dev Lowest active wall tick and highest one: the first and the last walls a sale meets.
    function _wallSpan() internal view returns (bool any, int24 lowest, int24 highest) {
        uint256 n = hook.activeWallCount();
        for (uint256 i; i < n; i++) {
            (int24 lower,,,) = hook.walls(hook.activeWallId(i));
            if (!any) (any, lowest, highest) = (true, lower, lower);
            else if (lower < lowest) lowest = lower;
            else if (lower > highest) highest = lower;
        }
    }

    /// @dev ETH committed to walls: principal at the current price, earmarked dust, funds not placed yet.
    function _floorEth() internal view returns (uint256) {
        (uint256 placed,) = hook.wallAmounts(_sqrtP());
        return placed + hook.wallIdleEth() + hook.pendingFloorEth();
    }

    /// @dev The 40/60 target in ETH per CUBIT, computed on prices rather than on the hook's tick maths.
    function _targetPrice(uint160 sqrtP) internal view returns (uint256) {
        uint256 launch = BandLib.ethPerCubitAtSqrt(hook.INITIAL_SQRT_PRICE());
        uint256 current = BandLib.ethPerCubitAtSqrt(sqrtP);
        return (current * 4_000 + launch * 6_000) / 10_000;
    }

    function _assertBooks() internal view {
        assertEq(
            manager.balanceOf(address(hook), 0),
            hook.pendingFloorEth() + hook.teamAccrued() + hook.wallIdleEth(),
            "ETH claims differ from the books"
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(token)))),
            hook.pendingAbsorbedTokens(),
            "CUBIT claims differ from the absorbed queue"
        );
        assertEq(token.balanceOf(address(hook)), 0, "hook holds raw CUBIT");
        assertEq(address(hook).balance, 0, "hook holds raw ETH");
        assertEq(token.totalSupply() + token.totalBurned(), token.TOTAL_SUPPLY(), "supply accounting");
    }

    /// @dev A sale empties every wall it fully crossed, so no active wall lies entirely below the market.
    function _assertNoCrossedWall() internal view {
        (bool any, int24 lowest,) = _wallSpan();
        if (any) assertLt(_tick(), lowest + hook.TICK_SPACING(), "a fully crossed wall remains");
    }

    /// @dev An exact-input sale nets g - ceil(15% g) from a gross g: find a gross behind `net` whose team share is
    ///      floor(tax / 5) and whose wall share is the rest (placed principal rounds down a wei or two).
    function _assertSellSplit(uint256 net, uint256 toTeam, uint256 toWalls) internal pure {
        uint256 guess = net * 10_000 / 8_500;
        for (uint256 g = guess > 4 ? guess - 4 : 0; g <= guess + 4; g++) {
            uint256 tax = FullMath.mulDivRoundingUp(g, 1_500, 10_000);
            if (tax > g || g - tax != net) continue;
            uint256 team_ = tax * 300 / 1_500;
            if (team_ == toTeam && toWalls <= tax - team_ && toWalls + 3 >= tax - team_) return;
        }
        revert("sell tax is not 15% split 12/3");
    }
}
