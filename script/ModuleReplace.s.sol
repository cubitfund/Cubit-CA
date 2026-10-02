// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitVault} from "../src/periphery/CubitVault.sol";
import {CubitRouter} from "../src/periphery/CubitRouter.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {CubitForge} from "../src/periphery/CubitForge.sol";
import {CubitGovernanceVault} from "../src/periphery/CubitGovernanceVault.sol";
import {ICubitHook} from "../src/interfaces/ICubitHook.sol";

/// @notice Replace each peripheral module from the authority. Every
///         replacement turns its feature flag off (re-activation is a separate, later decision)
///         and bumps moduleRevision. Run from the authority key. The replacement Forge keeps the governance vault of the
///         launchpad manifest (LAUNCHPAD) when one is given, and brings its own otherwise.
contract ModuleReplace is Script {
    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        CubitV2 v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        string memory launchpad = vm.envOr("LAUNCHPAD", string(""));

        uint256 rev0 = v2.moduleRevision();
        uint8 ef0 = v2.enabledFeatures();

        vm.startBroadcast();
        CubitVault nv = new CubitVault(hook);
        CubitRouter nr = new CubitRouter(pm, ICubitHook(address(hook)));
        CubitLens nl = new CubitLens(hook);
        address governanceVault = bytes(launchpad).length != 0
            ? vm.parseJsonAddress(vm.readFile(launchpad), ".governanceVault")
            : address(new CubitGovernanceVault());
        CubitForge nf = new CubitForge(hook, vm.envOr("FORGE_LAUNCH_FEE_WEI", uint256(0.005 ether)), governanceVault);

        v2.setVault(address(nv));
        require(v2.vault() == address(nv) && v2.enabledFeatures() & 1 == 0, "setVault");
        v2.setRouter(address(nr));
        require(v2.router() == address(nr) && v2.enabledFeatures() & 2 == 0, "setRouter");
        v2.setLens(address(nl));
        require(v2.lens() == address(nl) && v2.enabledFeatures() & 4 == 0, "setLens");
        v2.setForge(address(nf));
        require(v2.forge() == address(nf) && v2.enabledFeatures() & 8 == 0, "setForge");
        vm.stopBroadcast();

        require(v2.moduleRevision() == rev0 + 4, "revision not +4");
        require(v2.enabledFeatures() == 0, "all features must be off");

        console2.log("enabledFeatures", ef0, "->", v2.enabledFeatures());
        console2.log("moduleRevision", rev0, "->", v2.moduleRevision());
        console2.log("new vault ", address(nv));
        console2.log("new forge ", address(nf));
        console2.log("OK module replacement");
    }
}
