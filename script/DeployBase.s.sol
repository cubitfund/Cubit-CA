// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {CubitToken} from "../src/CubitToken.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitLens} from "../src/CubitLens.sol";
import {CubitRouter} from "../src/periphery/CubitRouter.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitVault} from "../src/periphery/CubitVault.sol";
import {CubitLaunch} from "../src/periphery/CubitLaunch.sol";
import {BandLib} from "../src/libraries/BandLib.sol";
import {WallLib} from "../src/libraries/WallLib.sol";

/// @notice Deployment and optional launch sequence shared by every network:
///           1. deploy CubitToken, then mine and deploy its CREATE2 hook
///           2. deploy and register the initial peripherals with all V2 flags at zero
///           3. wire token.setHook and approve the atomic launcher for the whole supply
///           4. launch: the pool allocation (80%) into the band, the other 20% into the vault's reward
///              reserve, optionally a taxed first buy
///         Core identities are fixed; the registry's setters replace peripherals. The launchpad (the Forge and its
///         governance vault) is not deployed at launch: script/LaunchpadDeploy.s.sol adds it later.
abstract contract DeployBase is Script {
    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    struct Deployed {
        CubitToken token;
        CubitHook hook;
        CubitLens lens;
        CubitRouter router;
        CubitV2 v2;
        CubitVault vault;
        CubitLaunch launch;
        bytes32 salt;
    }

    function _deployCubit(IPoolManager pm, address teamAddr) internal returns (Deployed memory d) {
        require(teamAddr != address(0), "TEAM_ADDRESS unset");

        // 2. token
        d.token = new CubitToken();

        // 1. mining — done here because the hook's init code embeds the token address
        uint256 launchEth = vm.envUint("LAUNCH_FDV_WEI");
        bytes memory ctorArgs = abi.encode(pm, d.token, teamAddr, launchEth);
        uint256 t0 = vm.unixTime();
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, FLAGS, type(CubitHook).creationCode, ctorArgs);
        console2.log("CREATE2 salt mined in ms:", vm.unixTime() - t0);
        d.salt = salt;

        // 3. hook at the mined address
        d.hook = new CubitHook{salt: salt}(pm, d.token, teamAddr, launchEth);
        require(address(d.hook) == predicted, "hook address mismatch");
        require(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK == FLAGS, "flags mismatch");

        // Register the initial modules before the supply can enter the pool. All flags stay zero.
        d.lens = new CubitLens(d.hook);
        d.router = new CubitRouter(pm, d.hook);
        d.vault = new CubitVault(d.hook);
        // No launchpad at launch: the registry starts without a Forge.
        d.v2 = new CubitV2(d.hook, address(d.vault), address(d.router), address(0), address(d.lens));
        d.hook.configureV2(address(d.v2));
        d.launch = new CubitLaunch(d.hook, d.router);

        // 4. one-shot wiring and an exact approval of the whole supply: the launcher takes all of it.
        d.token.setHook(address(d.hook));
        d.token.approve(address(d.launch), d.token.TOTAL_SUPPLY());

        // Keep the whole supply with the deployer until the atomic launch transaction.
        require(!d.hook.initialized(), "market already open");
        require(d.token.balanceOf(address(d.hook)) == 0, "hook funded before launch");
        require(d.token.balanceOf(d.token.deployer()) == d.token.TOTAL_SUPPLY(), "deployer must retain supply");
        require(d.v2.enabledFeatures() == 0, "V2 must remain disabled");
    }

    function _launchCubit(Deployed memory d) internal returns (uint256 bought) {
        // 5. pool init -> afterInitialize places the 80% deposit in one band [minUsableTick, launch tick];
        //    the launcher sends the other 20% to the vault's reward reserve, then makes the optional buy.
        uint256 buy = vm.envOr("INITIAL_BUY_WEI", uint256(0));
        uint256 minimum = vm.envOr("INITIAL_BUY_MIN_CUBIT", uint256(0));
        bought = d.launch.launch{value: buy}(minimum);
        require(d.hook.initialized(), "band not bootstrapped");
        require(
            d.vault.rewardReserve() == d.token.TOTAL_SUPPLY() - d.hook.MIN_POOL_SUPPLY(), "reward reserve not seeded"
        );
        require(d.v2.enabledFeatures() == 0, "V2 must remain disabled");
    }

    function _deploymentJson(Deployed memory d, IPoolManager pm, address teamAddr, uint256 bought)
        internal
        returns (string memory json)
    {
        string memory obj = "cubit";
        vm.serializeJson(obj, "{}");
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "poolManager", address(pm));
        vm.serializeAddress(obj, "bandLib", address(BandLib));
        vm.serializeAddress(obj, "wallLib", address(WallLib));
        vm.serializeAddress(obj, "token", address(d.token));
        vm.serializeAddress(obj, "hook", address(d.hook));
        vm.serializeAddress(obj, "lens", address(d.lens));
        vm.serializeAddress(obj, "router", address(d.router));
        vm.serializeAddress(obj, "v2", address(d.v2));
        vm.serializeAddress(obj, "vault", address(d.vault));
        vm.serializeAddress(obj, "launch", address(d.launch));
        vm.serializeUint(obj, "enabledFeatures", d.v2.enabledFeatures());
        vm.serializeUint(obj, "moduleRevision", d.v2.moduleRevision());
        vm.serializeBool(obj, "replaceableModules", true);
        vm.serializeBool(obj, "marketOpen", d.hook.initialized());
        vm.serializeAddress(obj, "deployer", d.token.deployer());
        vm.serializeUint(obj, "vaultLockDuration", d.vault.LOCK_DURATION());
        vm.serializeString(obj, "release", "v1-v2-prepared");
        vm.serializeAddress(obj, "teamAddress", teamAddr);
        vm.serializeBytes32(obj, "poolId", PoolId.unwrap(d.hook.poolId()));
        vm.serializeUint(obj, "deployBlock", block.number);
        vm.serializeUint(obj, "initialSqrtPriceX96", d.hook.INITIAL_SQRT_PRICE());
        vm.serializeUint(obj, "fee", d.hook.POOL_FEE());
        vm.serializeUint(obj, "wallRetracementBps", d.hook.WALL_RETRACEMENT_BPS());
        vm.serializeUint(obj, "wallUnderMarketBps", BandLib.WALL_UNDER_MARKET_BPS);
        vm.serializeUint(obj, "launchEthWei", d.hook.LAUNCH_ETH());
        vm.serializeString(obj, "wallPolicy", "40pct-current-plus-60pct-launch-at-deposit");
        vm.serializeInt(obj, "tickSpacing", d.hook.TICK_SPACING());
        json = vm.serializeBytes32(obj, "salt", d.salt);
        if (d.hook.initialized()) json = _serializeLaunch(obj, d, bought);
    }

    function _writeDeployment(
        Deployed memory d,
        IPoolManager pm,
        address teamAddr,
        string memory suffix,
        uint256 bought
    ) internal {
        string memory json = _deploymentJson(d, pm, teamAddr, bought);
        // A simulation cannot replace a live deployment manifest: the run writes a candidate, promoted
        // only after its receipts, runtime bytecode and on-chain wiring are checked.
        string memory path = string.concat("deployments/", vm.toString(block.chainid), suffix, ".candidate.json");
        vm.writeJson(json, path);
        console2.log("deployment written to", path);
        console2.log("token  ", address(d.token));
        console2.log("hook   ", address(d.hook));
        console2.log("lens   ", address(d.lens));
        console2.log("router ", address(d.router));
    }

    function _serializeLaunch(string memory obj, Deployed memory d, uint256 bought) internal returns (string memory) {
        vm.serializeBool(obj, "marketOpen", true);
        vm.serializeUint(obj, "launchTimestamp", d.hook.launchTimestamp());
        vm.serializeUint(obj, "launchBlock", block.number);
        vm.serializeUint(obj, "initialBuyWei", vm.envOr("INITIAL_BUY_WEI", uint256(0)));
        vm.serializeUint(obj, "initialBuyMinCubit", vm.envOr("INITIAL_BUY_MIN_CUBIT", uint256(0)));
        vm.serializeUint(obj, "initialBuyCubit", bought);
        return vm.serializeUint(obj, "rewardReserveAtLaunch", d.vault.rewardReserve());
    }
}
