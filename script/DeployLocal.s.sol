// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";
import {DeployBase} from "./DeployBase.s.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Local stack for anvil: a fresh PoolManager + quoter + state view, then CUBIT.
///
///   anvil --chain-id 31337 &
///   forge script script/DeployLocal.s.sol --rpc-url anvil --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Defaults: TEAM_ADDRESS falls back to anvil account #1 when unset.
contract DeployLocal is DeployBase {
    function run() external {
        address teamAddr = vm.envOr("TEAM_ADDRESS", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));

        // 3.75 ETH FDV: the 80% band (16.8M CUBIT) is worth exactly 3 ETH at the launch price.
        if (vm.envOr("LAUNCH_FDV_WEI", uint256(0)) == 0) vm.setEnv("LAUNCH_FDV_WEI", "3750000000000000000");
        vm.startBroadcast();
        IPoolManager pm = new PoolManager(address(0));
        V4Quoter quoter = new V4Quoter(pm);
        StateView stateView = new StateView(pm);
        Deployed memory d = _deployCubit(pm, teamAddr);
        uint256 bought = _launchCubit(d);
        vm.stopBroadcast();

        console2.log("quoter   ", address(quoter));
        console2.log("stateView", address(stateView));
        _writeDeployment(d, pm, teamAddr, ".local", bought);
        // periphery addresses for the dapp
        string memory obj = "periphery";
        vm.serializeAddress(obj, "quoter", address(quoter));
        string memory json = vm.serializeAddress(obj, "stateView", address(stateView));
        vm.writeJson(
            json, string.concat("deployments/", vm.toString(block.chainid), ".local.candidate.json"), ".periphery"
        );
    }
}
