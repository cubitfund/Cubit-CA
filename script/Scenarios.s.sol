// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {CubitToken} from "../src/CubitToken.sol";
import {CubitRouter} from "../src/periphery/CubitRouter.sol";
import {CubitVault} from "../src/periphery/CubitVault.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {BandLib} from "../src/libraries/BandLib.sol";
import {ICubitLens} from "../src/interfaces/ICubitLens.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ICubitHook} from "../src/interfaces/ICubitHook.sol";

/// @notice Replayable testnet scenarios. Select with SCENARIO= taxes | band | walls | crossing | lock. Each run is
///         one broadcast from a funded trader wallet, on a fresh deployment (state accumulates across
///         runs). Every step logs the figures the report needs; `band` and `walls` also assert them, so
///         a green run is the proof. Expected refusals are caught and printed, never recorded.
///         SCALE_BPS (default 10000) scales the sizes of `taxes` and `band` for a live network: with 500, `taxes`
///         spends about 0.07 ETH and `band` about 0.01 ETH. `walls` needs 4.2M CUBIT from outside the pool, which only
///         the Anvil recipe provides; `crossing` takes its sizes from WALLS and CYCLE_BUY_WEI.
contract Scenarios is Script {
    using StateLibrary for IPoolManager;

    CubitHook hook;
    CubitLens lens;
    CubitToken token;
    CubitRouter router;
    CubitVault vault;
    IPoolManager pm;
    PoolKey key;
    V4Quoter quoter;
    uint256 slippageBps;
    uint256 scaleBps;

    function run() external {
        require(block.chainid == 31337 || block.chainid == 11155111, "Scenarios are local/Sepolia only");
        string memory path = _deploymentPath();
        string memory json = vm.readFile(path);
        hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        // The registry names the Lens in force; the launch manifest keeps the one deployed at launch.
        lens = CubitLens(CubitV2(vm.parseJsonAddress(json, ".v2")).lens());
        router = CubitRouter(payable(vm.parseJsonAddress(json, ".router")));
        vault = CubitVault(vm.parseJsonAddress(json, ".vault"));
        pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        token = hook.token();
        key = hook.poolKey();
        require(address(router.hook()) == address(hook) && address(router.poolManager()) == address(pm), "Router mismatch");
        require(address(lens.hook()) == address(hook), "Lens mismatch");
        slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        require(slippageBps <= 500, "Slippage exceeds 5 percent");
        scaleBps = vm.envOr("SCALE_BPS", uint256(10_000));
        require(scaleBps != 0 && scaleBps <= 10_000, "SCALE_BPS must be in (0, 10000]");
        // Simulation-only quoter. It is never broadcast or called by a signed transaction.
        quoter = new V4Quoter(pm);
        string memory s = vm.envOr("SCENARIO", string("taxes"));
        bytes32 h = keccak256(bytes(s));

        vm.startBroadcast();
        if (h == keccak256("taxes")) _taxes();
        else if (h == keccak256("band")) _band();
        else if (h == keccak256("walls")) _walls();
        else if (h == keccak256("crossing")) _crossing();
        else if (h == keccak256("lock")) _lock();
        else revert("unknown SCENARIO");
        vm.stopBroadcast();
        _snap("end");
    }

    // S1 / S2: increasing buys in both modes, sells in both modes
    function _taxes() internal {
        uint256[4] memory sizes = [uint256(0.01 ether), 0.05 ether, 0.2 ether, 1 ether];
        for (uint256 i; i < 4; i++) {
            uint256 p0 = hook.pendingFloorEth();
            uint256 t0 = hook.teamAccrued();
            uint256 got = _swapIn(true, _scaled(sizes[i]));
            console2.log("S1 buy exact-in", _scaled(sizes[i]));
            console2.log("   CUBIT received", got);
            console2.log("   floor +", hook.pendingFloorEth() - p0);
            console2.log("   team  +", hook.teamAccrued() - t0);
        }
        uint256 spent = _swapOut(true, _scaled(100_000e18));
        console2.log("S1 buy exact-out (CUBIT), gross spent", _scaled(100_000e18), spent);
        uint256 bal = token.balanceOf(msg.sender);
        uint256 t1 = hook.teamAccrued();
        uint256 net = _swapIn(false, bal / 4);
        console2.log("S2 sell exact-in, net ETH", net);
        console2.log("   team +", hook.teamAccrued() - t1);
        uint256 used = _swapOut(false, _scaled(0.001 ether));
        console2.log("S2 sell exact-out (wei), CUBIT used", _scaled(0.001 ether), used);
    }

    // B1–B7: the pool allocation is ONE live band in the PoolManager, and the pool trades on its
    //        curve in all four modes. B1/B2 read the launch state: run on a fresh deployment.
    function _band() internal {
        uint256 startBalance = token.balanceOf(msg.sender);
        (int24 upper, uint128 liquidity, uint160 sqrtLaunch) = _bandAtLaunch();
        _bandBuyAndSell(upper, liquidity, sqrtLaunch);
        _bandExactOut();
        _books("B6");
        _bandRoundTrip(upper, token.balanceOf(msg.sender) - startBalance);
    }

    /// @dev B1 geometry, cross-checked against the PoolManager's own position record.
    ///      B2 launch state: the deposit sits in the band minus the integer dust burned at
    ///      bootstrap, the hook keeps no raw token and no claim, the band is not live above its top,
    ///      the vault's reward reserve holds the other 20% and the deployer keeps nothing.
    function _bandAtLaunch() internal view returns (int24 upper, uint128 liquidity, uint160 sqrtLaunch) {
        PoolId id = hook.poolId();
        int24 lower;
        (lower, upper, liquidity) = hook.band();
        int24 launchTick = TickMath.getTickAtSqrtPrice(hook.INITIAL_SQRT_PRICE());
        require(lower == TickMath.minUsableTick(hook.TICK_SPACING()), "B1 band lower is not the min usable tick");
        require(upper == BandLib.floorToSpacing(launchTick, hook.TICK_SPACING()), "B1 band upper is not the launch tick floored");
        require(liquidity != 0, "B1 empty band");
        (uint128 recorded,,) = pm.getPositionInfo(id, address(hook), lower, upper, hook.BAND_SALT());
        require(recorded == liquidity, "B1 PoolManager position differs from the hook book");
        console2.log("B1 band lower", lower);
        console2.log("   band upper", upper);
        console2.log("   launch tick", launchTick);
        console2.log("   liquidity", liquidity);
        console2.log("   virtual ETH depth at the top", FullMath.mulDiv(liquidity, FixedPoint96.Q96, TickMath.getSqrtPriceAtTick(upper)));

        int24 tick;
        (sqrtLaunch, tick,,) = pm.getSlot0(id);
        require(sqrtLaunch == hook.INITIAL_SQRT_PRICE() && tick >= upper, "B2 not a fresh deployment");
        require(pm.getLiquidity(id) == 0, "B2 band live above its top");
        uint256 deposit = hook.MIN_POOL_SUPPLY();
        uint256 dust = token.totalBurned();
        uint256 inBand = lens.bandTokens();
        uint256 reserve = token.TOTAL_SUPPLY() - deposit;
        require(dust < 10_000, "B2 bootstrap burned more than rounding dust");
        require(deposit - dust - inBand <= 1, "B2 band does not hold the deposit");
        require(token.balanceOf(address(hook)) == 0, "B2 hook holds raw CUBIT");
        require(pm.balanceOf(address(hook), uint256(uint160(address(token)))) == 0, "B2 hook holds CUBIT claims");
        require(vault.rewardReserve() == reserve && token.balanceOf(address(vault)) == reserve,
            "B2 the vault reward reserve does not hold the other 20%");
        require(token.balanceOf(token.deployer()) == 0, "B2 the deployer kept CUBIT at launch");
        (,, uint256 circulating) = _wallTotals(lens.snapshot());
        require(lens.rewardReserve() == reserve && circulating == token.totalSupply() - reserve,
            "B2 the circulating supply still counts the vault reserve");
        console2.log("B2 deposit (MIN_POOL_SUPPLY)", deposit);
        console2.log("   CUBIT in the band", inBand);
        console2.log("   dust burned at bootstrap", dust);
        console2.log("   vault reward reserve (the other 20%)", vault.rewardReserve());
    }

    /// @dev B3 exact-input buy: 3% to the team, the band becomes the live liquidity and pays out its
    ///      constant-product quote. B4 exact-input sell of half: 15% of the gross ETH, split 12/3.
    function _bandBuyAndSell(int24 upper, uint128 liquidity, uint160 sqrtLaunch) internal {
        PoolId id = hook.poolId();
        uint256 ethIn = _scaled(0.1 ether);
        uint256 team0 = hook.teamAccrued();
        uint256 quote = _bandBuyQuote(sqrtLaunch, upper, liquidity, ethIn);
        uint256 bought = _swapIn(true, ethIn);
        require(hook.teamAccrued() - team0 == FullMath.mulDivRoundingUp(ethIn, hook.BUY_TAX_BPS(), hook.BPS()),
            "B3 buy tax is not 3%");
        require(pm.getLiquidity(id) == liquidity, "B3 band is not the live liquidity");
        _requireClose(bought, quote, 1, "B3 CUBIT out is off the band curve");
        (uint160 sqrtNow,,,) = pm.getSlot0(id);
        console2.log("B3 buy exact-in (wei), CUBIT out", ethIn, bought);
        console2.log("   x*y=k quote on the band", quote);
        console2.log("   price before (ETH per CUBIT, 1e18)", BandLib.ethPerCubitAtSqrt(sqrtLaunch));
        console2.log("   price after", BandLib.ethPerCubitAtSqrt(sqrtNow));

        uint256 floor0 = _floorEthBooks();
        team0 = hook.teamAccrued();
        uint256 net = _swapIn(false, bought / 2);
        uint256 toTeam = hook.teamAccrued() - team0;
        uint256 toFloor = _floorEthBooks() - floor0;
        _requireSellSplit(net, toTeam, toFloor, "B4 sell tax is not 15% split 12/3");
        console2.log("B4 sell half exact-in, net ETH", net);
        console2.log("   to walls (placed + pending)", toFloor);
        console2.log("   to team", toTeam);
    }

    /// @dev B5 exact-output modes: a 100k CUBIT buy (3% added on top) and a 0.01 ETH sell (15%).
    function _bandExactOut() internal {
        uint256 team0 = hook.teamAccrued();
        uint256 spent = _swapOut(true, _scaled(100_000e18));
        uint256 buyTax = hook.teamAccrued() - team0;
        require(buyTax == FullMath.mulDivRoundingUp(spent - buyTax, hook.BUY_TAX_BPS(), hook.BPS() - hook.BUY_TAX_BPS()),
            "B5 exact-out buy tax is not 3%");
        team0 = hook.teamAccrued();
        uint256 ethOut = _scaled(0.01 ether);
        uint256 cubitIn = _swapOut(false, ethOut);
        uint256 sellTax = FullMath.mulDivRoundingUp(ethOut, hook.SELL_TAX_BPS(), hook.BPS() - hook.SELL_TAX_BPS());
        require(hook.teamAccrued() - team0 == sellTax * hook.SELL_TEAM_BPS() / hook.SELL_TAX_BPS(),
            "B5 exact-out sell tax is not 15% with a 3% team share");
        console2.log("B5 buy exact-out (CUBIT), gross ETH", _scaled(100_000e18), spent);
        console2.log("   sell exact-out (wei), CUBIT in", ethOut, cubitIn);
    }

    /// @dev B7 round trip: selling back everything this scenario bought walks the curve back under
    ///      the band's top. The band always holds the ETH for the CUBIT it sold.
    function _bandRoundTrip(int24 upper, uint256 held) internal {
        uint256 eth = _swapIn(false, held);
        (, int24 tick,,) = pm.getSlot0(hook.poolId());
        require(tick <= upper, "B7 round trip overshot the band top");
        console2.log("B7 sold back CUBIT", held);
        console2.log("   net ETH", eth);
        console2.log("   tick after", tick);
        console2.log("   ETH left in the band", lens.bandEth());
    }

    // W1–W7: every sale places its 12% at 40% of the price + 60% of the launch price (1% under the price
    //        below launch); a wall the price only enters stays and refills when the price comes back; a
    //        wall the price crosses is emptied and its CUBIT reach the vault reserve. Run on a fresh deployment.
    function _walls() internal {
        // W5 pushes the price past the band's top, which takes CUBIT from outside the pool: in production,
        // rewards paid from the vault reserve. Seed the trader with 4.2M first (the Anvil recipe moves them
        // out of the vault reserve by impersonation, standing in for rewards paid over time).
        require(token.balanceOf(msg.sender) >= token.TOTAL_SUPPLY() - hook.MIN_POOL_SUPPLY(),
            "walls: seed the trader with 4.2M CUBIT from outside the pool first");
        PoolSwapTest raw = new PoolSwapTest(pm); // price-limited sales, and a route that does not deliver
        token.approve(address(raw), type(uint256).max);
        _swapIn(true, 1 ether);
        uint256 id = _wallsFirstSale();
        _wallsEnteredStays(raw, id);
        _wallsCrossedPaysVault();
        _wallsUnderLaunch(raw);
        _books("W7");
    }

    /// @dev W1: a sale places its 12% at the 40/60 target of the price it leaves behind.
    function _wallsFirstSale() internal returns (uint256 id) {
        uint256 team0 = hook.teamAccrued();
        uint256 floor0 = _floorEthBooks();
        uint256 net = _swapIn(false, 200_000e18);
        _requireSellSplit(net, hook.teamAccrued() - team0, _floorEthBooks() - floor0, "W1 walls did not get 12%");
        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(hook.poolId());
        require(hook.activeWallCount() == 1, "W1 the sale placed no wall");
        id = hook.latestWallId();
        (int24 lower, uint128 liquidity,,) = hook.walls(id);
        require(lower == _wallTarget(sqrtP) && tick < lower && liquidity != 0, "W1 the wall is not at the 40/60 target");
        console2.log("W1 sale of 200k CUBIT placed wall", id);
        console2.log("   wall lower tick", lower);
        console2.log("   market tick", tick);
        console2.log("   wall price (ETH per CUBIT, 1e18)", BandLib.ethPerCubitAtTick(lower));
        console2.log("   market price", BandLib.ethPerCubitAtSqrt(sqrtP));
    }

    /// @dev W2: a sale that stops inside a wall leaves it in place, holding CUBIT, and delivers nothing.
    ///      W3: buying back through it sells those CUBIT back and restores exactly its ETH.
    function _wallsEnteredStays(PoolSwapTest raw, uint256 id) internal {
        (int24 lower, uint128 liquidity,,) = hook.walls(id);
        int24 upper = lower + hook.TICK_SPACING();
        (uint160 sqrt0,,,) = pm.getSlot0(hook.poolId());
        (uint256 eth0,) = BandLib.amountsForLiquidity(sqrt0, lower, upper, liquidity);
        uint256 reserve0 = vault.rewardReserve();
        uint160 inside = TickMath.getSqrtPriceAtTick(lower + hook.TICK_SPACING() / 2);
        raw.swap(key, SwapParams({zeroForOne: false, amountSpecified: -int256(5_000_000e18), sqrtPriceLimitX96: inside}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        (uint160 sqrt1, int24 tick1,,) = pm.getSlot0(hook.poolId());
        (, uint128 liquidity1,,) = hook.walls(id);
        (uint256 eth1, uint256 cubit1) = BandLib.amountsForLiquidity(sqrt1, lower, upper, liquidity1);
        require(tick1 >= lower && tick1 < upper, "W2 the sale did not stop inside the wall");
        require(liquidity1 == liquidity && cubit1 != 0, "W2 the entered wall moved or holds no CUBIT");
        require(hook.pendingAbsorbedTokens() == 0 && vault.rewardReserve() == reserve0, "W2 an entered wall was emptied");
        console2.log("W2 sale stopped inside wall", id);
        console2.log("   its ETH before", eth0);
        console2.log("   its ETH now", eth1);
        console2.log("   its CUBIT now", cubit1);

        _swapIn(true, 0.3 ether);
        (uint160 sqrt2, int24 tick2,,) = pm.getSlot0(hook.poolId());
        (uint256 eth2, uint256 cubit2) = BandLib.amountsForLiquidity(sqrt2, lower, upper, liquidity);
        require(tick2 < lower && cubit2 == 0, "W3 the price did not come back above the wall");
        require(eth2 + 1 >= eth0 && eth2 <= eth0 + 1, "W3 the wall did not refill with its ETH");
        console2.log("W3 buy back through the wall, its ETH again", eth2);
    }

    /// @dev W4: a sale through whole walls empties them, and the router delivers their CUBIT to the
    ///      vault reserve in the same transaction.
    function _wallsCrossedPaysVault() internal {
        uint256 walls0 = hook.activeWallCount();
        uint256 reserve0 = vault.rewardReserve();
        _swapIn(false, 3_000_000e18);
        uint256 delivered = vault.rewardReserve() - reserve0;
        require(delivered != 0, "W4 no CUBIT reached the vault reserve");
        require(hook.pendingAbsorbedTokens() == 0, "W4 the router left absorbed CUBIT undelivered");
        console2.log("W4 sale of 3M CUBIT, active walls before", walls0);
        console2.log("   active walls after", hook.activeWallCount());
        console2.log("   CUBIT delivered to the vault reserve", delivered);
    }

    /// @dev W5: a raw sale that exhausts every bid pushes the price past the band's top, under the launch
    ///      price. Every crossed wall is emptied and, the 40/60 target now being above the market, the sale
    ///      places its 12% 1% under the price instead of leaving it waiting; the sale still goes through.
    ///      W6: anyone delivers the CUBIT that route left behind.
    function _wallsUnderLaunch(PoolSwapTest raw) internal {
        (, int24 upper,) = hook.band();
        raw.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(2_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(upper + 2_000)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(hook.poolId());
        require(tick > upper, "W5 the sale did not exhaust the bids");
        require(hook.pendingFloorEth() <= 1, "W5 the 12% waited");
        require(hook.activeWallCount() == 1, "W5 a crossed wall was left in place, or no wall under the price");
        (int24 lower,,,) = hook.walls(hook.latestWallId());
        require(lower > tick && lower == BandLib.underMarketWallTarget(sqrtP, hook.TICK_SPACING()),
            "W5 the wall is not 1% under the price");
        uint256 absorbed = hook.pendingAbsorbedTokens();
        require(absorbed != 0, "W5 the crossed walls absorbed nothing");
        console2.log("W5 exhausting sale, tick", tick);
        console2.log("   its 12% placed 1% under the price, wall lower tick", lower);
        console2.log("   wall price (ETH per CUBIT, 1e18)", BandLib.ethPerCubitAtTick(lower));
        console2.log("   market price", BandLib.ethPerCubitAtSqrt(sqrtP));
        console2.log("   CUBIT awaiting delivery", absorbed);

        uint256 reserve0 = vault.rewardReserve();
        hook.deliverAbsorbed();
        require(vault.rewardReserve() - reserve0 == absorbed && hook.pendingAbsorbedTokens() == 0,
            "W6 the public delivery did not reach the vault reserve");
        console2.log("W6 public delivery to the vault reserve", absorbed);
    }

    // C1: gas of one sale through many walls. Builds WALLS distinct walls (a buy, then a sale of a tenth
    //     of it, which places its 12% above the previous wall), deploys a raw swapper and logs, nearest
    //     wall first, the price limit a sale must reach to fully cross k walls. The gas is measured per
    //     transaction outside the script, where every storage slot starts cold.
    function _crossing() internal {
        uint256 wanted = vm.envOr("WALLS", uint256(150));
        uint256 buy = vm.envOr("CYCLE_BUY_WEI", uint256(0.02 ether));
        for (uint256 i; hook.activeWallCount() < wanted; i++) {
            require(i < wanted * 3, "C1 the cycles stopped placing distinct walls");
            _swapIn(false, _swapIn(true, buy) / 10);
        }
        PoolSwapTest raw = new PoolSwapTest(pm);
        token.approve(address(raw), type(uint256).max);
        int24[] memory lowers = _wallLowersNearestFirst();
        (, int24 tick,,) = pm.getSlot0(hook.poolId());
        console2.log("C1 raw swapper", address(raw));
        console2.log("   pool fee", uint256(key.fee));
        console2.log("   active walls", lowers.length);
        console2.log("   market tick", tick);
        console2.log("   trader CUBIT", token.balanceOf(msg.sender));
        uint256[8] memory ks = [uint256(1), 25, 50, 100, 150, 200, 250, 300];
        for (uint256 j; j < ks.length && ks[j] < lowers.length; j++) {
            console2.log("C1 limit", ks[j], uint256(TickMath.getSqrtPriceAtTick(lowers[ks[j] - 1] + hook.TICK_SPACING())));
        }
        console2.log("C1 limit", lowers.length,
            uint256(TickMath.getSqrtPriceAtTick(lowers[lowers.length - 1] + hook.TICK_SPACING())));
    }

    /// @dev Active wall lower ticks in the order a sale meets them: lowest tick (highest price) first.
    function _wallLowersNearestFirst() internal view returns (int24[] memory lowers) {
        uint256 n = hook.activeWallCount();
        lowers = new int24[](n);
        for (uint256 i; i < n; i++) {
            (lowers[i],,,) = hook.walls(hook.activeWallId(i));
            for (uint256 j = i; j > 0 && lowers[j - 1] > lowers[j]; j--) {
                (lowers[j - 1], lowers[j]) = (lowers[j], lowers[j - 1]);
            }
        }
    }

    /// @dev The 40/60 target recomputed from internal maths, independently of the hook's own call.
    function _wallTarget(uint160 sqrtP) internal view returns (int24) {
        uint256 launch = BandLib.ethPerCubitAtSqrt(hook.INITIAL_SQRT_PRICE());
        uint256 current = BandLib.ethPerCubitAtSqrt(sqrtP);
        uint256 target = (current * 4_000 + launch * 6_000) / 10_000;
        int24 t = TickMath.getTickAtSqrtPrice(uint160(BandLib.sqrtPriceForRatio(target, 1e18)));
        return BandLib.ceilToSpacing(t + 1, hook.TICK_SPACING());
    }

    /// @dev ETH committed to walls: principal placed at the current price, earmarked dust, funds pending.
    function _floorEthBooks() internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(hook.poolId());
        (uint256 placed,) = hook.wallAmounts(sqrtP);
        return placed + hook.wallIdleEth() + hook.pendingFloorEth();
    }

    /// @dev An exact-input sale nets g - ceil(15% g) from a gross g. Find the gross behind `net`, then check
    ///      the team took floor(tax / 5) and the walls the rest (placed principal rounds down a wei or two).
    function _requireSellSplit(uint256 net, uint256 toTeam, uint256 toFloor, string memory err) internal view {
        uint256 guess = net * hook.BPS() / (hook.BPS() - hook.SELL_TAX_BPS());
        for (uint256 g = guess > 4 ? guess - 4 : 0; g <= guess + 4; g++) {
            uint256 tax = FullMath.mulDivRoundingUp(g, hook.SELL_TAX_BPS(), hook.BPS());
            if (g - tax != net) continue;
            uint256 team = tax * hook.SELL_TEAM_BPS() / hook.SELL_TAX_BPS();
            if (team == toTeam && toFloor <= tax - team && toFloor + 3 >= tax - team) return;
        }
        revert(err);
    }

    /// @dev Books: every ETH claim the hook holds belongs to an account; CUBIT claims only await delivery.
    function _books(string memory label) internal view {
        uint256 ethClaims = pm.balanceOf(address(hook), 0);
        require(ethClaims == hook.pendingFloorEth() + hook.teamAccrued() + hook.wallIdleEth(),
            string.concat(label, " ETH claims differ from the books"));
        require(pm.balanceOf(address(hook), uint256(uint160(address(token)))) == hook.pendingAbsorbedTokens(),
            string.concat(label, " CUBIT claims differ from the absorbed queue"));
        require(token.balanceOf(address(hook)) == 0, string.concat(label, " hook holds raw CUBIT"));
        console2.log(string.concat(label, " books match, hook ETH claims"), ethClaims);
    }

    /// @dev CUBIT a buy of `ethIn` gross gets from the band alone: the 3% tax comes off first, the
    ///      LP fee off the rest, then x*y=k on the band's virtual reserves from its top (the pool
    ///      opens in an empty gap above the top, which a buy crosses for free).
    function _bandBuyQuote(uint160 sqrtP, int24 upper, uint128 liquidity, uint256 ethIn)
        internal
        view
        returns (uint256)
    {
        uint160 top = TickMath.getSqrtPriceAtTick(upper);
        uint256 start = sqrtP < top ? sqrtP : top;
        uint256 net = ethIn - FullMath.mulDivRoundingUp(ethIn, hook.BUY_TAX_BPS(), hook.BPS());
        net = net * (1_000_000 - hook.POOL_FEE()) / 1_000_000;
        uint256 cubitReserve = FullMath.mulDiv(liquidity, start, FixedPoint96.Q96);
        uint256 ethReserve = FullMath.mulDiv(liquidity, FixedPoint96.Q96, start);
        return FullMath.mulDiv(cubitReserve, net, ethReserve + net);
    }

    /// @dev A size of the `taxes` and `band` scenarios, scaled by SCALE_BPS.
    function _scaled(uint256 amount) internal view returns (uint256) {
        return amount * scaleBps / 10_000;
    }

    function _requireClose(uint256 actual, uint256 expected, uint256 bps, string memory err) internal pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        require(diff * 10_000 <= expected * bps, err);
    }

    // S9 / S12: external liquidity must revert, claimTeam by anyone
    function _lock() internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        int24 t = lens.currentTick();
        int24 s = hook.TICK_SPACING();
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: t / s * s - 10 * s, tickUpper: t / s * s + 10 * s, liquidityDelta: 1e9, salt: 0
        });
        // I4: this MUST be refused. Do not record the refusal as a transaction.
        vm.stopBroadcast();
        try lp.modifyLiquidity(key, p, "") {
            revert("S9 FAILED: external liquidity accepted");
        } catch (bytes memory reason) {
            bytes memory expected = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector, address(hook), IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ICubitHook.ExternalLiquidityForbidden.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            require(keccak256(reason) == keccak256(expected), "S9 failed for an unrelated reason");
            console2.log("S9 ok: external liquidity reverted");
        }
        vm.startBroadcast();
        uint256 accrued = hook.teamAccrued();
        hook.claimTeam();
        console2.log("S12 claimTeam pushed", accrued);
        console2.log("    cumulative", hook.teamPaidCumulative());
    }

    function _quote(bool zeroForOne, uint256 amount, bool exactInput) internal returns (uint256 quoted) {
        require(amount > 0 && amount <= type(uint128).max, "Invalid quote amount");
        vm.stopBroadcast();
        IV4Quoter.QuoteExactSingleParams memory p = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amount), hookData: ""
        });
        (quoted,) = exactInput ? quoter.quoteExactInputSingle(p) : quoter.quoteExactOutputSingle(p);
        require(quoted > 0, "No executable quote");
        vm.startBroadcast();
    }

    function _swapIn(bool zeroForOne, uint256 amount) internal returns (uint256) {
        uint256 minimum = (_quote(zeroForOne, amount, true) * (10_000 - slippageBps) + 9999) / 10_000;
        if (!zeroForOne) token.approve(address(router), amount);
        return router.swapExactIn{value: zeroForOne ? amount : 0}(
            key, zeroForOne, amount, minimum, msg.sender, block.timestamp + 120
        );
    }

    function _swapOut(bool zeroForOne, uint256 amount) internal returns (uint256) {
        uint256 maximum = (_quote(zeroForOne, amount, false) * (10_000 + slippageBps) + 9999) / 10_000;
        if (!zeroForOne) token.approve(address(router), maximum);
        return router.swapExactOut{value: zeroForOne ? maximum : 0}(
            key, zeroForOne, amount, maximum, msg.sender, block.timestamp + 120
        );
    }

    function _snap(string memory tag) internal view {
        ICubitLens.Snapshot memory s = lens.snapshot();
        (uint256 wallEth,,) = _wallTotals(s);
        console2.log("---", tag);
        console2.log("floor      ", s.floorPrice);
        console2.log("net floor  ", s.netFloorPrice);
        console2.log("market     ", s.marketPrice);
        console2.log("tick       ", s.tick);
        console2.log("wallEth    ", wallEth);
        console2.log("pending    ", s.pendingFloorEth);
        console2.log("band ETH   ", s.bandEth);
        console2.log("band CUBIT ", s.bandTokens);
        console2.log("burned     ", s.totalBurned);
    }

    /// @dev Page size for the wall totals, the same one the app uses. The Lens imposes no limit; a script
    ///      reads locally, so this bounds the work per call, never a node's `eth_call` budget.
    uint256 constant WALL_PAGE = 500;

    /// @dev `snapshot()` no longer totals the walls. Sum every page at the block the snapshot was read at,
    ///      add the absorbed CUBIT awaiting delivery ONCE, then derive circulation exactly as the app does.
    function _wallTotals(ICubitLens.Snapshot memory s)
        internal
        view
        returns (uint256 wallEth, uint256 wallTokens, uint256 circulating)
    {
        for (uint256 start; start < s.activeWallCount;) {
            (uint256 eth, uint256 tokens, uint256 next,) = lens.wallAmountsPage(start, WALL_PAGE);
            require(next > start, "wall page did not advance");
            wallEth += eth;
            wallTokens += tokens;
            start = next;
        }
        wallTokens += s.pendingAbsorbedTokens;
        uint256 excluded = wallTokens + s.rewardReserve;
        circulating = s.totalSupply > excluded ? s.totalSupply - excluded : 0;
    }

    /// @dev A local deployment record is `deployments/<chainId>.local.json` (DeployLocal writes
    ///      `<chainId>.local.candidate.json`: copy it there) while a real deployment writes `<chainId>.json`;
    ///      resolve both.
    ///      `DEPLOYMENT` still overrides everything.
    function _deploymentPath() internal returns (string memory) {
        string memory override_ = vm.envOr("DEPLOYMENT", string(""));
        if (bytes(override_).length != 0) return override_;
        string memory canonical = string.concat("deployments/", vm.toString(block.chainid), ".json");
        if (vm.isFile(canonical)) return canonical;
        string memory local = string.concat("deployments/", vm.toString(block.chainid), ".local.json");
        if (vm.isFile(local)) return local;
        return canonical; // let readFile raise the canonical, informative error
    }
}
