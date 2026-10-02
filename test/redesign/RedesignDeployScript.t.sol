// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {DeployBase} from "../../script/DeployBase.s.sol";
import {Launch} from "../../script/Launch.s.sol";
import {ICubitHook} from "../../src/interfaces/ICubitHook.sol";

contract DeployScriptHarness is Launch {
    function deploy(IPoolManager manager, address signer) external returns (Deployed memory d) {
        vm.startBroadcast(signer);
        d = _deployCubit(manager, signer);
        vm.stopBroadcast();
    }

    function check(string memory json, address signer) external view {
        _readDeployment(json, signer);
    }

    function deployAndLaunch(IPoolManager manager, address signer)
        external
        returns (Deployed memory d, uint256 bought)
    {
        vm.startBroadcast(signer);
        d = _deployCubit(manager, signer);
        bought = _launchCubit(d);
        vm.stopBroadcast();
    }

    function open(string memory json, address signer) external returns (uint256 bought) {
        vm.startBroadcast(signer);
        (, address broadcaster,) = vm.readCallers();
        Deployed memory d = _readDeployment(json, broadcaster);
        bought = _launchCubit(d);
        vm.stopBroadcast();
    }

    function manifest(Deployed memory d, uint256 bought) external returns (string memory) {
        return _deploymentJson(d, d.hook.poolManager(), d.hook.TEAM_ADDRESS(), bought);
    }
}

contract RedesignDeployScriptTest is Test {
    DeployScriptHarness internal scripts;
    DeployBase.Deployed internal d;
    IPoolManager internal manager;
    address internal signer = makeAddr("deployer");
    string internal json;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_000_000);
        vm.roll(100);
        vm.setEnv("LAUNCH_FDV_WEI", "3750000000000000000");
        vm.setEnv("INITIAL_BUY_WEI", "100000000000000000");
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "1");
        // Foundry broadcast mode requires the canonical deterministic deployment proxy runtime.
        vm.etch(
            CREATE2_FACTORY,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        vm.deal(signer, 10 ether);
        manager = new PoolManager(address(0));
        scripts = new DeployScriptHarness();
        d = scripts.deploy(manager, signer);
        json = scripts.manifest(d, 0);
    }

    function test_deployLeavesTheMarketClosedAndSupplyWithDeployer() public view {
        assertFalse(d.hook.initialized());
        assertEq(d.token.balanceOf(address(d.hook)), 0);
        assertEq(d.token.balanceOf(signer), d.token.TOTAL_SUPPLY());
        assertEq(d.token.allowance(signer, address(d.launch)), d.token.TOTAL_SUPPLY());
        assertEq(d.vault.rewardReserve(), 0);
        assertEq(d.v2.enabledFeatures(), 0);
        assertFalse(vm.parseJsonBool(json, ".marketOpen"));
        assertFalse(vm.keyExistsJson(json, ".launchTimestamp"));
        assertFalse(vm.keyExistsJson(json, ".launchBlock"));
        assertFalse(vm.keyExistsJson(json, ".initialBuyWei"));
        scripts.check(json, signer);
    }

    function test_strangerCannotInitializeDuringTheWaitThenDeployerLaunches() public {
        PoolKey memory key = d.hook.poolKey();
        uint160 price = d.hook.INITIAL_SQRT_PRICE();
        vm.warp(2_000_000);
        vm.roll(200);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(d.hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(ICubitHook.SupplyNotDeposited.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, price);
        assertFalse(d.hook.initialized());
        uint256 bought = scripts.open(json, signer);
        assertTrue(d.hook.initialized());
        assertEq(d.hook.launchTimestamp(), 2_000_000);
        assertEq(d.token.balanceOf(signer), bought);
        assertEq(bought, 526108113121399541651328);
        assertEq(d.vault.rewardReserve(), d.token.TOTAL_SUPPLY() - d.hook.MIN_POOL_SUPPLY());
        assertEq(d.v2.enabledFeatures(), 0);
        string memory launched = scripts.manifest(d, bought);
        assertTrue(vm.parseJsonBool(launched, ".marketOpen"));
        assertEq(vm.parseJsonUint(launched, ".launchBlock"), 200);
        assertEq(vm.parseJsonUint(launched, ".initialBuyWei"), 0.1 ether);
        assertEq(vm.parseJsonUint(launched, ".initialBuyCubit"), bought);
        vm.expectRevert("market already open");
        scripts.check(json, signer);
    }

    function test_launchWithNoBuyStillSeedsTheReserve() public {
        vm.prank(signer);
        assertEq(d.launch.launch(0), 0);
        assertTrue(d.hook.initialized());
        assertEq(d.token.balanceOf(signer), 0);
        assertEq(d.vault.rewardReserve(), 4_200_000e18);
    }

    function test_localSequenceStillDeploysAndLaunchesInOneExecution() public {
        (DeployBase.Deployed memory local, uint256 bought) = scripts.deployAndLaunch(manager, signer);
        assertTrue(local.hook.initialized());
        assertEq(local.token.balanceOf(signer), bought);
        assertEq(local.vault.rewardReserve(), 4_200_000e18);
        assertEq(local.v2.enabledFeatures(), 0);
        assertTrue(vm.parseJsonBool(scripts.manifest(local, bought), ".marketOpen"));
    }

    function test_preflightRejectsAnotherSignerOrMissingApproval() public {
        vm.expectRevert("signer is not token deployer");
        scripts.check(json, makeAddr("stranger"));
        vm.prank(signer);
        d.token.approve(address(d.launch), 0);
        vm.expectRevert("launch approval missing");
        scripts.check(json, signer);
    }

    function test_preflightRejectsChangedPricePoolOrChain() public {
        vm.serializeJson("changed", json);
        string memory changed = vm.serializeUint("changed", "initialSqrtPriceX96", 1);
        vm.expectRevert("initial price mismatch");
        scripts.check(changed, signer);
        vm.serializeJson("changed", json);
        changed = vm.serializeBytes32("changed", "poolId", bytes32(uint256(1)));
        vm.expectRevert("pool ID mismatch");
        scripts.check(changed, signer);
        vm.chainId(1);
        vm.expectRevert("manifest chain mismatch");
        scripts.check(json, signer);
    }

    function test_preflightRejectsChangedBindingsAndEnabledFeatures() public {
        vm.mockCall(address(d.hook), abi.encodeWithSignature("v2()"), abi.encode(address(1)));
        vm.expectRevert("registry mismatch");
        scripts.check(json, signer);
        vm.clearMockedCalls();
        vm.mockCall(address(d.token), abi.encodeWithSignature("hook()"), abi.encode(address(1)));
        vm.expectRevert("token hook mismatch");
        scripts.check(json, signer);
        vm.clearMockedCalls();
        vm.mockCall(address(d.v2), abi.encodeWithSignature("enabledFeatures()"), abi.encode(uint8(1)));
        vm.expectRevert("V2 must remain disabled");
        scripts.check(json, signer);
    }

    function test_failedDevBuyRollsBackPoolAndSupply() public {
        uint256 minimum = d.token.TOTAL_SUPPLY();
        vm.prank(signer);
        vm.expectRevert();
        d.launch.launch{value: 0.1 ether}(minimum);
        assertFalse(d.hook.initialized());
        assertEq(d.token.balanceOf(address(d.hook)), 0);
        assertEq(d.token.balanceOf(signer), d.token.TOTAL_SUPPLY());
        assertEq(d.vault.rewardReserve(), 0);
    }
}
