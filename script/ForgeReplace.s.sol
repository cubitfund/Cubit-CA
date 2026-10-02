// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitForge} from "../src/periphery/CubitForge.sol";
import {CubitGovernanceVault} from "../src/periphery/CubitGovernanceVault.sol";

/// @notice Replaces the public Forge with a launchpad v2, here to change the launch fee: same hook template and same
///         governance vault, which keeps its deposits and its only claimant. When the signer is the team address, the new
///         Forge is registered in the same run; otherwise the script prints the `setForge` call the team must send. The
///         replaced Forge stops launching; the tokens it launched keep their pools. `setForge` turns the launchpad off, so
///         activation stays a separate, explicit transaction by the team:
///           cast send <v2> 'activate(uint8)' 8 --account <team keystore> --password-file <file>
///         Reads DEPLOYMENT (the CUBIT launch manifest) and LAUNCHPAD (the launchpad manifest in force), and writes
///         deployments/<chainId>.launchpad.candidate.json, checked like a first launchpad:
///           DEPLOYMENT=deployments/11155111.json LAUNCHPAD=deployments/11155111.launchpad.json \
///             forge script script/ForgeReplace.s.sol --rpc-url sepolia --broadcast --account <team keystore> ...
contract ForgeReplace is Script {
    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        CubitV2 v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        string memory launchpad = vm.readFile(vm.envString("LAUNCHPAD"));
        CubitForge previous = CubitForge(vm.parseJsonAddress(launchpad, ".forge"));
        CubitGovernanceVault governanceVault = CubitGovernanceVault(vm.parseJsonAddress(launchpad, ".governanceVault"));
        uint256 fee = vm.envOr("FORGE_LAUNCH_FEE_WEI", uint256(0.005 ether));
        require(v2.forge() == address(previous), "the registry names another Forge than the launchpad manifest");
        require(previous.governanceVault() == address(governanceVault), "the launchpad manifest names another governance vault");
        bool signerIsTeam = msg.sender == v2.authority();

        vm.startBroadcast();
        CubitForge forge = new CubitForge(hook, fee, address(governanceVault));
        if (signerIsTeam) v2.setForge(address(forge));
        vm.stopBroadcast();

        require(forge.launchFee() == fee, "unexpected launch fee");
        require(forge.governanceVault() == address(governanceVault), "the new Forge names another governance vault");
        require(forge.hookCreationCodeHash() == previous.hookCreationCodeHash(), "the new Forge links another hook template");
        require(v2.forge() == (signerIsTeam ? address(forge) : address(previous)), "unexpected Forge in the registry");
        require(!signerIsTeam || v2.enabledFeatures() & v2.FORGE() == 0, "setForge must leave the launchpad inactive");

        string memory obj = "launchpad";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "hook", address(hook));
        vm.serializeAddress(obj, "v2", address(v2));
        vm.serializeAddress(obj, "forge", address(forge));
        vm.serializeAddress(obj, "governanceVault", address(governanceVault));
        vm.serializeUint(obj, "forgeLaunchFee", forge.launchFee());
        vm.serializeUint(obj, "governanceLockDuration", governanceVault.LOCK_DURATION());
        vm.serializeUint(obj, "governanceLockExtension", governanceVault.lockExtension());
        vm.serializeAddress(obj, "governanceDeployer", governanceVault.deployer());
        vm.serializeBytes32(obj, "hookCreationCodeHash", forge.hookCreationCodeHash());
        string memory out = vm.serializeUint(obj, "deployBlock", block.number);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".launchpad.candidate.json");
        vm.writeJson(out, path);

        console2.log("launchpad written to", path);
        console2.log("replaced forge  ", address(previous));
        console2.log("forge           ", address(forge));
        console2.log("launch fee (wei)", forge.launchFee());
        console2.log("governanceVault ", address(governanceVault));
        if (signerIsTeam) {
            console2.log("OK forge replaced, inactive until activate(8)");
        } else {
            console2.log("The signer is not the team address: the team must send setForge(forge) to the registry", address(v2));
            console2.log("calldata:");
            console2.logBytes(abi.encodeCall(CubitV2.setForge, (address(forge))));
            console2.log("OK forge deployed, not registered until the team's setForge, then activate(8)");
        }
    }
}
