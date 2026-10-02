// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {CubitToken} from "../src/CubitToken.sol";
import {CubitRouter} from "../src/periphery/CubitRouter.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {ICubitLens} from "../src/interfaces/ICubitLens.sol";

/// @notice Post-deploy smoke test: one buy, one sell, read every view.
///
///   forge script script/Smoke.s.sol --rpc-url <net> --account <trader> --broadcast
///
/// Env: DEPLOYMENT, BUY_ETH (default 0.01 ether), MIN_BUY_OUT and MIN_SELL_OUT in base units.
/// Obtain both positive minimums from a recent quote with the desired slippage tolerance.
contract Smoke is Script {
    function run() external {
        string memory path = _deploymentPath();
        string memory json = vm.readFile(path);
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        // The registry names the Lens in force; the launch manifest keeps the one deployed at launch.
        CubitLens lens = CubitLens(CubitV2(vm.parseJsonAddress(json, ".v2")).lens());
        CubitRouter router = CubitRouter(payable(vm.parseJsonAddress(json, ".router")));
        CubitToken token = hook.token();
        PoolKey memory key = hook.poolKey();
        uint256 buyEth = vm.envOr("BUY_ETH", uint256(0.01 ether));
        uint256 minBuy = vm.envUint("MIN_BUY_OUT");
        uint256 minSell = vm.envUint("MIN_SELL_OUT");
        require(minBuy > 0 && minSell > 0, "Positive quote minimums required");

        _print(lens, "before");
        vm.startBroadcast();
        uint256 got = router.swapExactIn{value: buyEth}(key, true, buyEth, minBuy, msg.sender, block.timestamp + 600);
        console2.log("bought CUBIT:", got);
        token.approve(address(router), got / 2);
        uint256 eth = router.swapExactIn(key, false, got / 2, minSell, msg.sender, block.timestamp + 600);
        console2.log("sold half, net ETH:", eth);
        vm.stopBroadcast();
        _print(lens, "after");
    }

    /// @dev Page size for the wall totals, the same one the app uses. The Lens imposes no limit; a script
    ///      reads locally, so this bounds the work per call, never a node's `eth_call` budget.
    uint256 constant WALL_PAGE = 500;

    function _print(CubitLens lens, string memory tag) internal view {
        ICubitLens.Snapshot memory s = lens.snapshot();
        (uint256 wallEth,, uint256 circulating) = _wallTotals(lens, s);
        console2.log("---", tag, "---");
        console2.log("floorPrice (ETH/CUBIT 1e18):", s.floorPrice);
        console2.log("netFloorPrice:", s.netFloorPrice);
        console2.log("marketPrice:", s.marketPrice);
        console2.log("wallEth:", wallEth);
        console2.log("pendingFloorEth:", s.pendingFloorEth);
        console2.log("bandEth:", s.bandEth);
        console2.log("bandTokens:", s.bandTokens);
        console2.log("circulatingSupply:", circulating);
        console2.log("totalBurned:", s.totalBurned);
    }

    /// @dev `snapshot()` no longer totals the walls. Sum every page at the block the snapshot was read at,
    ///      add the absorbed CUBIT awaiting delivery ONCE, then derive circulation exactly as the app does.
    function _wallTotals(CubitLens lens, ICubitLens.Snapshot memory s)
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
