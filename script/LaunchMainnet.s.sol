// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MainnetConfig} from "./DeployMainnet.s.sol";
import {LaunchBase} from "./LaunchBase.s.sol";

/// @notice Check and simulate the atomic mainnet launch before preparing its single transaction.
contract LaunchMainnet is LaunchBase, MainnetConfig {
    uint256 public constant MIN_EXPECTED_BUY_BPS = 9900;

    function run() external {
        require(block.chainid == 1, "this release script is mainnet-only");
        // DEPLOYMENT names the verified deployment record.
        string memory source = vm.envOr("DEPLOYMENT", string("deployments/1.deployed.json"));
        string memory json = vm.readFile(source);

        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        vm.stopBroadcast();
        Deployed memory d = _readMainnetDeployment(json, signer);
        (uint256 expected, bool allowAnyPrice) = _previewInitialBuy(d, signer);

        vm.startBroadcast();
        uint256 bought = _launchCubit(d);
        vm.stopBroadcast();

        vm.writeJson(
            _mainnetLaunchJson(json, d, bought, expected, allowAnyPrice), "deployments/1.launch.candidate.json"
        );
    }

    function _readMainnetDeployment(string memory json, address signer) internal view returns (Deployed memory d) {
        _mainnetPoolManager();
        _checkMainnetTeam(signer);
        d = _readDeployment(json, signer);
        require(address(d.hook.poolManager()) == MAINNET_POOL_MANAGER, "noncanonical mainnet PoolManager");
        require(d.hook.TEAM_ADDRESS() == signer, "team must be the signer");
    }

    function _previewInitialBuy(Deployed memory d, address signer)
        internal
        returns (uint256 expected, bool allowAnyPrice)
    {
        require(
            bytes(vm.envOr("INITIAL_BUY_MIN_CUBIT", string(""))).length != 0,
            "INITIAL_BUY_MIN_CUBIT is required on mainnet"
        );
        uint256 minimum = vm.envUint("INITIAL_BUY_MIN_CUBIT");
        require(minimum != 0, "INITIAL_BUY_MIN_CUBIT must be positive on mainnet");
        allowAnyPrice = keccak256(bytes(vm.envOr("ALLOW_ANY_PRICE", string("")))) == keccak256("1");
        uint256 buy = vm.envOr("INITIAL_BUY_WEI", uint256(0));

        // No broadcast is active. Use the deployed contracts and actual manager state, including fees.
        // Restore the entire launch: supply, approval, band, pool, reserve and ETH balances.
        uint256 snapshot = vm.snapshotState();
        vm.prank(signer, signer);
        expected = d.launch.launch{value: buy}(1);
        require(vm.revertToStateAndDelete(snapshot), "launch preview rollback failed");

        console2.log("Dev buy ETH (wei):", buy);
        console2.log("Expected dev buy CUBIT (base units):", expected);
        console2.log("INITIAL_BUY_MIN_CUBIT (base units):", minimum);
        if (minimum <= expected) console2.log("Expected minus minimum (base units):", expected - minimum);
        else console2.log("Minimum above expected (base units):", minimum - expected);
        uint256 floor = FullMath.mulDivRoundingUp(expected, MIN_EXPECTED_BUY_BPS, 10_000);
        console2.log("99% of expected, rounded up (base units):", floor);
        console2.log("ALLOW_ANY_PRICE=1:", allowAnyPrice);
        require(
            minimum >= floor || allowAnyPrice,
            "INITIAL_BUY_MIN_CUBIT below 99% of expected; set ALLOW_ANY_PRICE=1 to override"
        );
    }

    function _mainnetLaunchJson(
        string memory json,
        Deployed memory d,
        uint256 bought,
        uint256 expected,
        bool allowAnyPrice
    ) internal returns (string memory) {
        string memory obj = "cubit-mainnet-launch";
        vm.serializeJson(obj, _launchJson(json, d, bought));
        vm.serializeUint(obj, "initialBuyExpectedCubit", expected);
        return vm.serializeBool(obj, "allowAnyPrice", allowAnyPrice);
    }
}
