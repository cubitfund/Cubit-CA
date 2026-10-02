// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";

/// @notice Economic attempts on the walls, which hold ETH other traders paid in taxes.
///         - A trader alone in one block (flash-loan style, no price risk), any mix of buys, sales and sales stopped at
///           a price limit: asserted to leave with at most the funds that were waiting to be placed.
///         - Measured, numbers logged: a crash under the launch price leaves no waiting funds to capture, buying
///           around another trader's large sale, and an early buyer selling everything into the walls.
///         Bounded strategies, not a theorem about every strategy.
contract RedesignEconomicsTest is RedesignBase {
    address internal attacker = makeAddr("attacker");
    address internal whale = makeAddr("whale");
    address internal victim = makeAddr("victim");
    address[3] internal crowd = [makeAddr("crowd0"), makeAddr("crowd1"), makeAddr("crowd2")];

    // ------------------------------------------------------------------ property

    /// One trader, one block, starting with ETH only. Whatever the mix of buys, sales and price-limited sales, and
    /// whatever walls the crowd built before, the trader sells everything and leaves with at most its ETH plus the funds
    /// that were waiting: pending wall funds, ETH earmarked for wall ticks, the pool fee the crowd's buys paid, and any
    /// ETH already sitting in a router (both refund their whole balance to their next caller; on a fork their addresses
    /// can hold some before deployment). Walls under the market are out of its reach: reaching them takes CUBIT it did
    /// not buy in this block.
    function testFuzz_oneBlockTraderTakesAtMostTheWaitingFunds(uint256 seed, uint256 rounds, uint256[6] memory ops)
        public
    {
        uint256 crowdBuys = _crowdTrades(seed, bound(rounds, 0, 10), 3 ether);
        uint256 waiting = hook.pendingFloorEth() + hook.wallIdleEth() + crowdBuys / 10_000 + address(router).balance
            + address(swapRouter).balance + 1;
        vm.deal(attacker, 200 ether);
        for (uint256 i; i < ops.length; i++) {
            _attackStep(ops[i]);
        }
        uint256 left = token.balanceOf(attacker);
        if (left != 0) _rawSell(attacker, left, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(token.balanceOf(attacker), 0, "the trader kept CUBIT nobody would buy");
        assertLe(attacker.balance, 200 ether + waiting, "a one-block trader took more than the waiting funds");
        _assertBooks();
        _assertNoCrossedWall();
    }

    function _attackStep(uint256 op) internal {
        uint256 x = op >> 8;
        if (op % 4 == 0) {
            uint256 eth = bound(x, 1e12, 30 ether);
            vm.prank(attacker);
            router.swapExactIn{value: eth}(key, true, eth, 0, attacker, type(uint256).max);
        } else if (op % 4 == 1) {
            uint256 amount = token.balanceOf(attacker) * bound(x, 1, 10_000) / 10_000;
            if (amount != 0) _sell(attacker, amount);
        } else if (op % 4 == 2) {
            uint256 amount = token.balanceOf(attacker) * bound(x % 10_000, 1, 10_000) / 10_000;
            int256 limit = int256(_tick()) + int256(bound(x >> 16, 1, 20_000));
            if (limit >= TickMath.MAX_TICK) limit = TickMath.MAX_TICK - 1;
            if (amount != 0) _rawSell(attacker, amount, TickMath.getSqrtPriceAtTick(int24(limit)));
        } else {
            hook.deliverAbsorbed();
        }
    }

    // ------------------------------------------------------------------ measurements

    /// Measured: a crash under the launch price, the case where wall funds used to wait for a later sale. Each sale now
    /// places its own 12% 1% under the price, so nothing piles up, and buying before a sale, selling 1 CUBIT and dumping
    /// into what it placed only costs the trader its taxes.
    function test_measure_crashUnderLaunchLeavesNothingToCapture() public {
        _clearStrayRouterEth();
        _crowdTrades(0xDEAD, 10, 0.5 ether);
        address dumper = makeAddr("dumper");
        for (uint256 i; i < 3; i++) {
            uint256 held = token.balanceOf(crowd[i]);
            if (held == 0) continue;
            vm.prank(crowd[i]);
            token.transfer(dumper, held);
        }
        _giveReserveCubit(dumper, RESERVE);
        (, int24 upper,) = hook.band();
        uint256 waitingMax;
        _rawSell(dumper, token.balanceOf(dumper) * 9 / 10, TickMath.getSqrtPriceAtTick(upper + 1_000));
        waitingMax = hook.pendingFloorEth();
        int24 from = _tick() > upper ? _tick() : upper;
        _rawSell(dumper, token.balanceOf(dumper), TickMath.getSqrtPriceAtTick(from + 1_000));
        if (hook.pendingFloorEth() > waitingMax) waitingMax = hook.pendingFloorEth();
        assertGt(_tick(), upper, "the crash did not go under the launch price");
        assertLe(waitingMax, 1, "wall funds piled up during the crash");
        _assertBooks();
        uint256 launchPrice = BandLib.ethPerCubitAtSqrt(hook.INITIAL_SQRT_PRICE());
        console2.log(
            string.concat(
                "after the crash: price ", vm.toString(BandLib.ethPerCubitAtSqrt(_sqrtP()) * 1000 / launchPrice),
                "/1000 of launch, ", vm.toString(hook.activeWallCount()), " walls, waiting funds ",
                vm.toString(hook.pendingFloorEth()), " wei"
            )
        );
        console2.log("buy | trader result");
        uint256[5] memory buyEth = [uint256(0.3 ether), 1 ether, 3 ether, 6 ether, 12 ether];
        for (uint256 j; j < buyEth.length; j++) {
            uint256 snap = vm.snapshotState();
            vm.deal(attacker, buyEth[j]);
            vm.prank(attacker);
            uint256 bought = router.swapExactIn{value: buyEth[j]}(key, true, buyEth[j], 0, attacker, type(uint256).max);
            _sell(attacker, 1e18);
            _sell(attacker, bought - 1e18);
            int256 result = int256(attacker.balance) - int256(buyEth[j]);
            assertLt(result, 0, "the trader gained");
            _assertBooks();
            console2.log(string.concat(_eth(buyEth[j]), " | ", _signedEth(result)));
            vm.revertToState(snap);
        }
    }

    /// Measured: another trader's large sale places its own 12% at the price after that sale. A trader buys just before
    /// it and sells everything just after, into the wall that sale placed higher than it would have been alone.
    function test_measure_buyAroundAnotherTradersSale() public {
        _clearStrayRouterEth();
        uint256 held = _buy(victim, 5 ether);
        _crowdTrades(0xBEEF, 10, 1 ether);
        uint256[3] memory saleBps = [uint256(2_000), 5_000, 10_000];
        uint256[4] memory buyEth = [uint256(0.5 ether), 2 ether, 5 ether, 10 ether];
        console2.log("victim sells (bps of holdings) | victim alone | trader buys | trader result | victim gets");
        for (uint256 i; i < saleBps.length; i++) {
            uint256 amount = held * saleBps[i] / 10_000;
            uint256 snap = vm.snapshotState();
            uint256 aloneEth = _sell(victim, amount);
            vm.revertToState(snap);
            for (uint256 j; j < buyEth.length; j++) {
                snap = vm.snapshotState();
                uint256 waiting = hook.pendingFloorEth() + hook.wallIdleEth();
                vm.deal(attacker, buyEth[j]);
                vm.prank(attacker);
                uint256 bought = router.swapExactIn{value: buyEth[j]}(key, true, buyEth[j], 0, attacker, type(uint256).max);
                uint256 got = _sell(victim, amount);
                _sell(attacker, bought);
                int256 result = int256(attacker.balance) - int256(buyEth[j]);
                _assertBooks();
                _assertNoCrossedWall();
                console2.log(
                    string.concat(
                        vm.toString(saleBps[i]), " | ", _eth(aloneEth), " | ", _eth(buyEth[j]), " | ",
                        _signedEth(result), " | ", _eth(got)
                    )
                );
                // Bound: the waiting funds plus the 12% the victim's sale placed.
                assertLe(result, int256(waiting + got * 1_200 / 8_500 + 1), "the trader took more than the victim's 12%");
                vm.revertToState(snap);
            }
        }
    }

    /// The scenario behind "can an early buyer drain the walls": a buyer at launch, a crowd that trades the price up and
    /// builds walls, then the early buyer sells everything at once.
    function test_measure_earlyBuyerSellsEverythingIntoTheWalls() public {
        _clearStrayRouterEth();
        uint256 paid = 1 ether;
        uint256 bought = _buy(whale, paid);
        uint256 crowdBuys = _crowdTrades(0xC0FFEE, 40, 1 ether);
        uint256 launchPrice = BandLib.ethPerCubitAtSqrt(hook.INITIAL_SQRT_PRICE());
        uint160 sqrtBefore = _sqrtP();
        (uint256 wallEth0,) = hook.wallAmounts(sqrtBefore);
        uint256 walls0 = hook.activeWallCount();
        uint256 reserve0 = vault.rewardReserve();
        uint256 pending0 = hook.pendingFloorEth();
        uint256 team0 = hook.teamAccrued();

        uint256 received = _sell(whale, bought);

        uint160 sqrtAfter = _sqrtP();
        (uint256 wallEth1,) = hook.wallAmounts(sqrtAfter);
        // After the sale the hook places its 12% (four times the team's 3%, to 4 wei) and the funds that waited.
        uint256 placed = 4 * (hook.teamAccrued() - team0) + pending0 - hook.pendingFloorEth();
        uint256 wallsPaid = wallEth0 + placed > wallEth1 ? wallEth0 + placed - wallEth1 : 0;
        assertLe(_cubitAt(received, sqrtBefore), bought, "the sale was filled above the spot");
        assertEq(hook.pendingAbsorbedTokens(), 0, "the router did not deliver the absorbed CUBIT");
        _assertNoCrossedWall();
        _assertBooks();

        console2.log(
            string.concat(
                "early buyer: paid ", _eth(paid), " ETH at launch for ", vm.toString(bought / 1e18), " CUBIT (",
                vm.toString(bought * 10_000 / token.TOTAL_SUPPLY()), " bps of the supply)"
            )
        );
        console2.log(
            string.concat(
                "crowd: 40 buys and partial sales, ", _eth(crowdBuys), " ETH of buys; price ",
                vm.toString(BandLib.ethPerCubitAtSqrt(sqrtBefore) * 1000 / launchPrice), "/1000 of launch; ",
                vm.toString(walls0), " walls holding ", _eth(wallEth0), " ETH"
            )
        );
        console2.log(
            string.concat(
                "early buyer sells everything: receives ", _eth(received), " ETH (x",
                vm.toString(received * 1000 / paid), "/1000); price falls to ",
                vm.toString(BandLib.ethPerCubitAtSqrt(sqrtAfter) * 1000 / launchPrice), "/1000 of launch"
            )
        );
        console2.log(
            string.concat(
                "walls paid about ", _eth(wallsPaid), " ETH of ", _eth(wallEth0), "; ",
                vm.toString(hook.activeWallCount()), " walls left holding ", _eth(wallEth1),
                " ETH (its own 12% included); CUBIT absorbed into the vault reserve: ",
                vm.toString((vault.rewardReserve() - reserve0) / 1e18)
            )
        );

        // The rest of the market can still sell into what is left.
        uint256 half = token.balanceOf(crowd[0]) / 2;
        if (half != 0) assertGt(_sell(crowd[0], half), 0, "a later seller found no bid");
        _assertBooks();
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Others trade: a buy, then a partial sale that places a wall under the new price. Returns the ETH the crowd
    ///      spent on buys: the pool fee on it (0.01%) is the only ETH their trades can leave in a wall position.
    function _crowdTrades(uint256 seed, uint256 rounds, uint256 maxBuy) internal returns (uint256 buyEth) {
        for (uint256 i; i < rounds; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 eth = 0.01 ether + (r >> 8) % maxBuy;
            _buy(crowd[r % 3], eth);
            buyEth += eth;
            address seller = crowd[(r >> 128) % 3];
            uint256 amount = token.balanceOf(seller) * (1 + (r >> 136) % 7_000) / 10_000;
            if (amount != 0) _sell(seller, amount);
        }
    }

    /// @dev Measure from empty routers: on a fork their addresses can already hold ETH, which they refund to their next
    ///      caller and which would otherwise count in the trader's result.
    function _clearStrayRouterEth() internal {
        vm.deal(address(router), 0);
        vm.deal(address(swapRouter), 0);
    }

    /// @dev Wei as ETH with six decimals.
    function _eth(uint256 amount) internal pure returns (string memory) {
        string memory frac = vm.toString(amount % 1 ether / 1e12);
        while (bytes(frac).length < 6) {
            frac = string.concat("0", frac);
        }
        return string.concat(vm.toString(amount / 1 ether), ".", frac);
    }

    function _signedEth(int256 amount) internal pure returns (string memory) {
        return amount < 0 ? string.concat("-", _eth(uint256(-amount))) : string.concat("+", _eth(uint256(amount)));
    }
}
