// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchBase} from "./LaunchBase.s.sol";

/// @notice Open a deployed Sepolia market in one transaction, after checking its manifest and wiring.
///         DEPLOYMENT names the verified deployment record (default deployments/11155111.deployed.json); it is
///         preserved, and the run writes deployments/11155111.launch.candidate.json.
contract Launch is LaunchBase {
    function run() external {
        require(block.chainid == 11155111, "this release script is Sepolia-only");
        string memory source = vm.envOr("DEPLOYMENT", string("deployments/11155111.deployed.json"));
        string memory json = vm.readFile(source);

        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        Deployed memory d = _readDeployment(json, signer);
        uint256 bought = _launchCubit(d);
        vm.stopBroadcast();

        vm.writeJson(_launchJson(json, d, bought), "deployments/11155111.launch.candidate.json");
    }
}
