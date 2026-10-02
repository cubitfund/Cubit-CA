// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {DeployBase} from "./DeployBase.s.sol";
import {CubitToken} from "../src/CubitToken.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {CubitRouter} from "../src/periphery/CubitRouter.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitVault} from "../src/periphery/CubitVault.sol";
import {CubitLaunch} from "../src/periphery/CubitLaunch.sol";

/// @notice Manifest checks and launch serialization shared by the release scripts.
abstract contract LaunchBase is DeployBase {
    function _launchJson(string memory json, Deployed memory d, uint256 bought) internal returns (string memory) {
        string memory obj = "cubit-launch";
        vm.serializeJson(obj, json);
        // A simulation is not evidence that the launch was broadcast.
        vm.serializeBool(obj, "runtimeVerified", false);
        vm.serializeBool(obj, "broadcastVerified", false);
        return _serializeLaunch(obj, d, bought);
    }

    function _readDeployment(string memory json, address signer) internal view returns (Deployed memory d) {
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "manifest chain mismatch");
        require(!vm.parseJsonBool(json, ".marketOpen"), "manifest market already open");
        require(vm.parseJsonUint(json, ".enabledFeatures") == 0, "manifest V2 must remain disabled");
        d.token = CubitToken(vm.parseJsonAddress(json, ".token"));
        d.hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        d.v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        d.vault = CubitVault(vm.parseJsonAddress(json, ".vault"));
        d.router = CubitRouter(payable(vm.parseJsonAddress(json, ".router")));
        d.lens = CubitLens(vm.parseJsonAddress(json, ".lens"));
        d.launch = CubitLaunch(payable(vm.parseJsonAddress(json, ".launch")));

        require(!d.hook.initialized(), "market already open");
        require(d.hook.v2() == address(d.v2) && address(d.v2.hook()) == address(d.hook), "registry mismatch");
        require(d.token.hook() == address(d.hook) && address(d.hook.token()) == address(d.token), "token hook mismatch");
        require(signer == d.token.deployer(), "signer is not token deployer");
        require(signer == vm.parseJsonAddress(json, ".deployer"), "manifest deployer mismatch");
        require(d.token.balanceOf(signer) == d.token.TOTAL_SUPPLY(), "deployer must retain supply");
        require(d.token.balanceOf(address(d.hook)) == 0, "hook funded before launch");
        require(d.token.allowance(signer, address(d.launch)) >= d.token.TOTAL_SUPPLY(), "launch approval missing");
        require(
            address(d.launch.hook()) == address(d.hook) && address(d.launch.token()) == address(d.token),
            "launcher mismatch"
        );
        require(d.hook.INITIAL_SQRT_PRICE() == vm.parseJsonUint(json, ".initialSqrtPriceX96"), "initial price mismatch");
        require(address(d.hook.poolManager()) == vm.parseJsonAddress(json, ".poolManager"), "pool manager mismatch");
        require(PoolId.unwrap(d.hook.poolId()) == vm.parseJsonBytes32(json, ".poolId"), "pool ID mismatch");
        require(d.hook.LAUNCH_ETH() == vm.parseJsonUint(json, ".launchEthWei"), "launch FDV mismatch");
        require(d.hook.TEAM_ADDRESS() == vm.parseJsonAddress(json, ".teamAddress"), "team mismatch");
        require(d.v2.enabledFeatures() == 0, "V2 must remain disabled");
        require(d.v2.moduleRevision() == 0 && vm.parseJsonUint(json, ".moduleRevision") == 0, "modules changed");
        require(d.v2.vault() == address(d.vault) && address(d.vault.hook()) == address(d.hook), "vault mismatch");
        require(d.vault.rewardReserve() == 0, "vault already funded");
        require(d.v2.router() == address(d.router) && address(d.router.hook()) == address(d.hook), "router mismatch");
        require(d.v2.lens() == address(d.lens) && d.v2.forge() == address(0), "modules mismatch");
    }
}
