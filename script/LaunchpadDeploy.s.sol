// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitForge} from "../src/periphery/CubitForge.sol";
import {CubitGovernanceVault} from "../src/periphery/CubitGovernanceVault.sol";

/// @notice Adds the launchpad after the CUBIT launch: deploys the governance vault, then the public Forge, then registers
///         the Forge in the registry. The key that runs this script deploys the governance vault and is the only one
///         that can ever claim from it or extend its lock: run it with the protected key. `setForge` only accepts the
///         team address, which is the deployer key. When the signer
///         is that address the Forge is registered in the same run; otherwise the script registers nothing and prints
///         the `setForge` call the team must send. Activation
///         stays a separate, explicit transaction by the team:
///           cast send <v2> 'activate(uint8)' 8 --account <team keystore> --password-file <file>
///         Reads DEPLOYMENT (the CUBIT launch manifest) and writes deployments/<chainId>.launchpad.candidate.json:
///           DEPLOYMENT=deployments/31337.local.candidate.json forge script script/LaunchpadDeploy.s.sol \
///             --rpc-url anvil --broadcast --account <protected keystore> --password-file <file>
contract LaunchpadDeploy is Script {
    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        CubitV2 v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        uint256 fee = vm.envOr("FORGE_LAUNCH_FEE_WEI", uint256(0.005 ether));
        require(v2.forge() == address(0), "a launchpad is already registered: use a replacement instead");
        bool signerIsTeam = msg.sender == v2.authority();

        vm.startBroadcast();
        CubitGovernanceVault governanceVault = new CubitGovernanceVault();
        CubitForge forge = new CubitForge(hook, fee, address(governanceVault));
        if (signerIsTeam) v2.setForge(address(forge));
        vm.stopBroadcast();

        require(governanceVault.deployer() == msg.sender, "the governance vault names another deployer");
        require(forge.governanceVault() == address(governanceVault), "the Forge names another governance vault");
        require(v2.forge() == (signerIsTeam ? address(forge) : address(0)), "unexpected Forge in the registry");
        require(v2.enabledFeatures() & v2.FORGE() == 0, "the launchpad must stay inactive until the team activates it");

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
        console2.log("forge           ", address(forge));
        console2.log("governanceVault ", address(governanceVault));
        console2.log("governance deployer, the only claimer", governanceVault.deployer());
        if (signerIsTeam) {
            console2.log("OK launchpad registered, inactive until activate(8)");
        } else {
            console2.log("The signer is not the team address: the team must send setForge(forge) to the registry", address(v2));
            console2.log("calldata:");
            console2.logBytes(abi.encodeCall(CubitV2.setForge, (address(forge))));
            console2.log("OK launchpad deployed, not registered until the team's setForge, then activate(8)");
        }
    }
}
