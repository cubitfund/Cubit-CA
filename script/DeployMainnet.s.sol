// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Fixed mainnet identity, shared by deployment and launch.
abstract contract MainnetConfig is Script {
    address public constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _mainnetPoolManager() internal view returns (IPoolManager) {
        require(block.chainid == 1, "this release script is mainnet-only");
        require(
            vm.envOr("POOL_MANAGER", MAINNET_POOL_MANAGER) == MAINNET_POOL_MANAGER,
            "POOL_MANAGER differs from canonical mainnet PoolManager"
        );
        require(MAINNET_POOL_MANAGER.code.length != 0, "canonical mainnet PoolManager has no code");
        return IPoolManager(MAINNET_POOL_MANAGER);
    }

    function _checkMainnetTeam(address signer) internal view {
        require(vm.envAddress("TEAM_ADDRESS") == signer, "TEAM_ADDRESS must be the signer");
    }
}

/// @notice Deploy and wire CUBIT on Ethereum mainnet, leaving the market closed.
contract DeployMainnet is DeployBase, MainnetConfig {
    function run() external {
        require(block.chainid == 1, "this release script is mainnet-only");
        vm.startBroadcast();
        Deployed memory d = _deployMainnet();
        vm.stopBroadcast();

        _writeDeployment(d, d.hook.poolManager(), d.token.deployer(), "", 0);
    }

    function _deployMainnet() internal returns (Deployed memory) {
        IPoolManager pm = _mainnetPoolManager();
        (, address signer,) = vm.readCallers();
        _checkMainnetTeam(signer);
        return _deployCubit(pm, signer);
    }
}
