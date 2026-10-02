// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";

/// @notice Limits raised in review:
///         - Sandwich variant of large sales: buying before another trader's large sale, whose 12% is then placed at the 40/60
///           target of a price the buy pushed up, and selling into that wall in the same block.
///         - Gas of one sale through many walls against the 16,777,216 gas cap of a transaction (EIP-7825).
contract RedesignLimitsTest is RedesignBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    address internal alice = makeAddr("alice");
    address internal victim = makeAddr("victim");
    address internal frontRunner = makeAddr("frontRunner");

    // ------------------------------------------------------------------ large sales

    /// A front-runner buys, a large sale places its 12% at the 40/60 target of a price the buy pushed up, and the
    /// front-runner sells everything into that wall in the same block: never a gain.
    function testFuzz_largeSaleTwelvePercentIsNotCapturable(uint256 victimEth, uint256 saleBps, uint256 frontEth)
        public
    {
        victimEth = bound(victimEth, 40 ether, 150 ether);
        saleBps = bound(saleBps, 2_000, 10_000);
        frontEth = bound(frontEth, 0.5 ether, 60 ether);
        (int256 result,) = _sandwich(victimEth, saleBps, frontEth);
        assertLe(result, 0, "the front-runner gained from a large sale's wall");
    }

    /// Measured: the same sandwich on a grid of sale sizes and front-run sizes.
    function test_measure_largeSaleSandwich() public {
        uint256[3] memory victimEth = [uint256(40 ether), 80 ether, 150 ether];
        uint256[3] memory saleBps = [uint256(3_000), 6_000, 10_000];
        uint256[4] memory frontEth = [uint256(1 ether), 5 ether, 20 ether, 60 ether];
        console2.log("victim bought for | sold (bps of holdings) | victim net ETH | front-run | front-runner result");
        for (uint256 i; i < victimEth.length; i++) {
            for (uint256 s; s < saleBps.length; s++) {
                for (uint256 f; f < frontEth.length; f++) {
                    uint256 snap = vm.snapshotState();
                    (int256 result, uint256 victimNet) = _sandwich(victimEth[i], saleBps[s], frontEth[f]);
                    console2.log(
                        string.concat(
                            _eth(victimEth[i]), " | ", vm.toString(saleBps[s]), " | ", _eth(victimNet), " | ",
                            _eth(frontEth[f]), " | ", _signedEth(result)
                        )
                    );
                    assertLe(result, 0, "the front-runner gained from a large sale's wall");
                    vm.revertToState(snap);
                }
            }
        }
    }

    function _sandwich(uint256 victimEth, uint256 saleBps, uint256 frontEth)
        internal
        returns (int256 result, uint256 victimNet)
    {
        vm.deal(address(router), 0);
        vm.deal(address(swapRouter), 0);
        uint256 amount = _buy(victim, victimEth) * saleBps / 10_000;
        vm.deal(frontRunner, frontEth);
        vm.prank(frontRunner);
        uint256 bought = router.swapExactIn{value: frontEth}(key, true, frontEth, 0, frontRunner, type(uint256).max);
        victimNet = _sell(victim, amount);
        _sell(frontRunner, bought);
        result = int256(frontRunner.balance) - int256(frontEth);
        _assertBooks();
        _assertNoCrossedWall();
    }

    // ------------------------------------------------------------------ gas at the transaction cap

    /// One sale through 80 walls fits one transaction. Gas depends on cold storage, so these tests run only as
    /// separate transactions:
    ///   CUBIT_GAS_ISOLATED=true FOUNDRY_TEST=test/redesign forge test --isolate --mt test_gas_ -vv
    function test_gas_saleThroughEightyWallsFitsOneTransaction() public {
        vm.skip(!vm.envOr("CUBIT_GAS_ISOLATED", false), "needs CUBIT_GAS_ISOLATED=true and --isolate");
        (uint256[] memory ids, int24[] memory ticks) = _wallsToCross(80);
        // Build the calldata before the prank: its external reads would consume the prank.
        bytes memory sale = _rawSale(token.balanceOf(alice), ticks[79]);
        vm.prank(alice);
        (bool ok,) = address(swapRouter).call{gas: TX_GAS_CAP}(sale);
        Vm.Gas memory gas = vm.lastCallGas();
        console2.log("gas of one sale through 80 walls", gas.gasTotalUsed);
        assertTrue(ok, "80 walls do not fit one transaction");
        for (uint256 i; i < ids.length; i++) {
            (, uint128 liquidity,,) = hook.walls(ids[i]);
            assertEq(liquidity, 0, "a crossed wall was left in place");
        }
        _assertBooks();
    }

    /// A sale through 120 walls does not fit: it reverts without loss, and the same sale split at the 60th wall fits in
    /// two transactions.
    function test_gas_saleThroughTooManyWallsRevertsWithoutLossAndASplitFits() public {
        vm.skip(!vm.envOr("CUBIT_GAS_ISOLATED", false), "needs CUBIT_GAS_ISOLATED=true and --isolate");
        (, int24[] memory ticks) = _wallsToCross(120);
        uint256 amount = token.balanceOf(alice);
        uint256 eth0 = alice.balance;
        // Build the calldata before each prank: its external reads would consume the prank.
        bytes memory sale = _rawSale(amount, ticks[119]);
        vm.prank(alice);
        (bool ok,) = address(swapRouter).call{gas: TX_GAS_CAP}(sale);
        console2.log("gas of the refused sale through 120 walls", vm.lastCallGas().gasTotalUsed);
        assertFalse(ok, "120 walls fit one transaction");
        assertEq(token.balanceOf(alice), amount, "the refused sale lost CUBIT");
        assertEq(alice.balance, eth0, "the refused sale moved ETH");
        assertEq(hook.activeWallCount(), 120, "the refused sale emptied walls");

        sale = _rawSale(amount, ticks[59]);
        vm.prank(alice);
        (ok,) = address(swapRouter).call{gas: TX_GAS_CAP}(sale);
        console2.log("gas of the first half", vm.lastCallGas().gasTotalUsed);
        assertTrue(ok, "the first half does not fit");
        sale = _rawSale(token.balanceOf(alice), ticks[119]);
        vm.prank(alice);
        (ok,) = address(swapRouter).call{gas: TX_GAS_CAP}(sale);
        console2.log("gas of the second half", vm.lastCallGas().gasTotalUsed);
        assertTrue(ok, "the second half does not fit");
        _assertNoCrossedWall();
        _assertBooks();
    }

    /// @dev Build n walls with buy-then-small-sale cycles (each places its wall nearer the market), give alice CUBIT from
    ///      the reserve and approve the raw route. Returns the walls sorted nearest first.
    function _wallsToCross(uint256 n) internal returns (uint256[] memory ids, int24[] memory ticks) {
        for (uint256 i; hook.activeWallCount() < n; i++) {
            require(i < 4 * n, "cycles stopped placing distinct walls");
            uint256 got = _buy(alice, 0.02 ether);
            _sell(alice, got / 10);
        }
        _giveReserveCubit(alice, 4_000_000e18);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        ids = new uint256[](n);
        ticks = new int24[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = hook.activeWallId(i);
            (ticks[i],,,) = hook.walls(ids[i]);
        }
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && ticks[j - 1] > ticks[j]; j--) {
                (ticks[j - 1], ticks[j]) = (ticks[j], ticks[j - 1]);
                (ids[j - 1], ids[j]) = (ids[j], ids[j - 1]);
            }
        }
    }

    /// @dev A raw sale of `amount` stopping just past the wall at `lower`.
    function _rawSale(uint256 amount, int24 lower) internal view returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(lower + hook.TICK_SPACING())
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
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
