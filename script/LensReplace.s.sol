// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {ICubitLens} from "../src/interfaces/ICubitLens.sol";

/// @dev The totals a Lens from before pagination computes on chain. A replaced Lens keeps answering after `setLens`: it
///      reads the hook, not the registry, so both Lenses can be compared on the same state.
interface IFormerLens {
    function wallEth() external view returns (uint256);
    function wallTokens() external view returns (uint256);
    function circulatingSupply() external view returns (uint256);
    function heldSupply() external view returns (uint256);
}

/// @notice Replaces the Lens alone: same hook, same pool, same token, and nothing else in the registry moves. The Lens
///         holds no funds and no authority; it only reads the hook. Deployment and registration are separate on purpose:
///         the app decodes `snapshot()` with the ABI it was built with, so `setLens` has to be timed with the app release
///         that speaks the new ABI. By default the script only deploys and proves the candidate; with REGISTER=true and
///         the team address as signer it also sends `setLens`. `setLens` turns Momentum off, so re-activation stays a
///         separate, explicit transaction by the team:
///           cast send <v2> 'setLens(address)' <lens> --account <team keystore> --password-file <file>
///           cast send <v2> 'activate(uint8)' 4 --account <team keystore> --password-file <file>
///         The checks below run in the simulation, before anything is broadcast: the candidate passes what `setLens`
///         checks, answers for this block, and its paginated totals equal the ones the Lens in force computes on chain
///         (when that Lens still exposes them). Reads DEPLOYMENT (the CUBIT launch manifest) and writes
///         deployments/<chainId>.lens.candidate.json:
///           DEPLOYMENT=deployments/11155111.json forge script script/LensReplace.s.sol --rpc-url sepolia --broadcast \
///             --account <keystore> ...
contract LensReplace is Script {
    /// @dev Page size for the wall totals, the same one the app uses. The Lens imposes no limit; a script reads locally,
    ///      so this bounds the work per call, never a node's `eth_call` budget.
    uint256 constant WALL_PAGE = 500;

    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        CubitV2 v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        // The registry names the Lens in force; the launch manifest keeps the one deployed at launch.
        address previous = v2.lens();
        bool register = vm.envOr("REGISTER", false);
        require(!register || msg.sender == v2.authority(), "REGISTER needs the team address as signer");
        uint256 revision = v2.moduleRevision();
        uint8 features = v2.enabledFeatures();

        vm.startBroadcast();
        CubitLens lens = new CubitLens(hook);
        if (register) v2.setLens(address(lens));
        vm.stopBroadcast();

        // What `setLens` checks, so that a deployment alone already proves the registry will accept the candidate.
        require(address(lens.hook()) == address(hook), "the new Lens reads another hook");
        require(address(lens.poolManager()) == address(hook.poolManager()), "the new Lens reads another PoolManager");
        require(PoolId.unwrap(lens.poolId()) == PoolId.unwrap(hook.poolId()), "the new Lens reads another pool");
        require(address(lens.token()) == address(hook.token()), "the new Lens reads another token");
        bool compared = _proveTotals(hook, lens, previous);

        uint8 momentum = v2.MOMENTUM();
        if (register) {
            require(v2.lens() == address(lens), "setLens did not register the new Lens");
            require(v2.moduleRevision() == revision + 1, "setLens must bump the revision once");
            require(v2.enabledFeatures() == features & ~momentum, "setLens must only turn Momentum off");
        } else {
            require(v2.lens() == previous && v2.moduleRevision() == revision && v2.enabledFeatures() == features,
                "a deployment alone must leave the registry untouched");
        }

        string memory obj = "lens";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "hook", address(hook));
        vm.serializeAddress(obj, "v2", address(v2));
        vm.serializeAddress(obj, "previousLens", previous);
        vm.serializeAddress(obj, "lens", address(lens));
        vm.serializeBool(obj, "registered", register);
        vm.serializeBool(obj, "comparedWithPreviousLens", compared);
        string memory out = vm.serializeUint(obj, "deployBlock", block.number);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".lens.candidate.json");
        vm.writeJson(out, path);

        console2.log("lens candidate written to", path);
        console2.log("replaced lens", previous);
        console2.log("lens         ", address(lens));
        console2.log(compared ? "totals equal the previous Lens at this block" : "the previous Lens exposes no on-chain totals: comparison skipped");
        if (register) {
            console2.log(features & momentum != 0 ? "OK lens replaced, Momentum inactive until activate(4)" : "OK lens replaced");
        } else {
            console2.log("Not registered. When the app that speaks this ABI is live, the team sends to the registry", address(v2));
            console2.log("calldata:");
            console2.logBytes(abi.encodeCall(CubitV2.setLens, (address(lens))));
            console2.log(features & momentum != 0 ? "OK lens deployed, then setLens and activate(4)" : "OK lens deployed, then setLens");
        }
    }

    /// @dev The candidate answers for this block and mirrors the hook, then its pages, summed as the app sums them, must
    ///      equal the totals the previous Lens computes on chain. Returns false when that Lens is already a paginated one.
    function _proveTotals(CubitHook hook, CubitLens lens, address previous) internal view returns (bool compared) {
        ICubitLens.Snapshot memory s = lens.snapshot();
        require(s.blockNumber == block.number, "the new Lens answered for another block");
        require(s.activeWallCount == hook.activeWallCount(), "the new Lens counts other active walls than the hook");
        require(s.pendingAbsorbedTokens == hook.pendingAbsorbedTokens(), "the new Lens reads other pending CUBIT than the hook");
        require(s.totalSupply == hook.token().totalSupply(), "the new Lens reads another total supply");

        uint256 wallEth;
        uint256 wallTokens;
        for (uint256 start; start < s.activeWallCount;) {
            (uint256 eth, uint256 tokens, uint256 next, uint256 total) = lens.wallAmountsPage(start, WALL_PAGE);
            require(total == s.activeWallCount && next > start, "inconsistent wall page");
            wallEth += eth;
            wallTokens += tokens;
            start = next;
        }
        wallTokens += s.pendingAbsorbedTokens;
        uint256 excluded = wallTokens + s.rewardReserve;
        uint256 circulating = s.totalSupply > excluded ? s.totalSupply - excluded : 0;
        uint256 held = circulating > s.bandTokens ? circulating - s.bandTokens : 0;
        console2.log("active walls      ", s.activeWallCount);
        console2.log("wallEth           ", wallEth);
        console2.log("wallTokens        ", wallTokens);
        console2.log("circulatingSupply ", circulating);
        console2.log("heldSupply        ", held);

        try IFormerLens(previous).wallEth() returns (uint256 formerWallEth) {
            require(wallEth == formerWallEth, "wallEth differs from the previous Lens");
            require(wallTokens == IFormerLens(previous).wallTokens(), "wallTokens differs from the previous Lens");
            require(circulating == IFormerLens(previous).circulatingSupply(), "circulatingSupply differs from the previous Lens");
            require(held == IFormerLens(previous).heldSupply(), "heldSupply differs from the previous Lens");
            compared = true;
        } catch {}
    }
}
