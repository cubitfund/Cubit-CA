// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploy and wire CUBIT on Sepolia, leaving the market closed. Launch.s.sol opens it later.
///
///   forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify
///
/// Required env: POOL_MANAGER, TEAM_ADDRESS (see .env.example). The salt is mined at
/// run time; the deployment record keeps it.
contract Deploy is DeployBase {
    function run() external {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address teamAddr = vm.envAddress("TEAM_ADDRESS");
        require(block.chainid == 11155111, "this release script is Sepolia-only");

        vm.startBroadcast();
        Deployed memory d = _deployCubit(pm, teamAddr);
        vm.stopBroadcast();

        _writeDeployment(d, pm, teamAddr, "", 0);
    }
}
