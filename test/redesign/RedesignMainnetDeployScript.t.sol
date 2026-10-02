// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {DeployBase} from "../../script/DeployBase.s.sol";
import {DeployMainnet} from "../../script/DeployMainnet.s.sol";
import {LaunchMainnet} from "../../script/LaunchMainnet.s.sol";
import {ICubitHook} from "../../src/interfaces/ICubitHook.sol";
import {CubitRouter} from "../../src/periphery/CubitRouter.sol";

contract MainnetDeployScriptHarness is DeployMainnet {
    function deploy(address signer) external returns (Deployed memory d) {
        vm.startBroadcast(signer);
        d = _deployMainnet();
        vm.stopBroadcast();
    }

    function manifest(Deployed memory d) external returns (string memory) {
        return _deploymentJson(d, d.hook.poolManager(), d.token.deployer(), 0);
    }
}

contract MainnetLaunchScriptHarness is LaunchMainnet {
    function check(string memory json, address signer) external view {
        _readMainnetDeployment(json, signer);
    }

    function preview(string memory json, address signer) external returns (uint256 expected, bool allowAnyPrice) {
        return _previewInitialBuy(_readMainnetDeployment(json, signer), signer);
    }

    function open(string memory json, address signer) external returns (uint256 bought, string memory launched) {
        Deployed memory d = _readMainnetDeployment(json, signer);
        (uint256 expected, bool allowAnyPrice) = _previewInitialBuy(d, signer);
        vm.startBroadcast(signer);
        bought = _launchCubit(d);
        vm.stopBroadcast();
        launched = _mainnetLaunchJson(json, d, bought, expected, allowAnyPrice);
    }
}

contract RedesignMainnetDeployScriptTest is Test {
    using StateLibrary for IPoolManager;

    MainnetDeployScriptHarness internal deployment;
    MainnetLaunchScriptHarness internal launch;
    DeployBase.Deployed internal d;
    IPoolManager internal manager;
    address internal signer = makeAddr("mainnet deployer");
    string internal json;
    uint256 internal constant EXPECTED_BUY = 526108113121399541651328;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_000_000);
        vm.roll(100);
        _resetEnvironment();
        vm.etch(
            CREATE2_FACTORY,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        deployment = new MainnetDeployScriptHarness();
        launch = new MainnetLaunchScriptHarness();
        // Run the local constructor at the canonical address, preserving NoDelegateCall's self immutable.
        manager = IPoolManager(deployment.MAINNET_POOL_MANAGER());
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(0)), address(manager));
        vm.deal(signer, 10 ether);
        d = deployment.deploy(signer);
        json = deployment.manifest(d);
    }

    // vm.setEnv is process-wide. Run script tests with --threads 1 and reset it for every case.
    modifier configuredEnvironment() {
        _resetEnvironment();
        _;
        _resetEnvironment();
    }

    function _resetEnvironment() internal {
        vm.setEnv("LAUNCH_FDV_WEI", "3750000000000000000");
        vm.setEnv("INITIAL_BUY_WEI", "100000000000000000");
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "525000000000000000000000");
        vm.setEnv("ALLOW_ANY_PRICE", "0");
        vm.setEnv("TEAM_ADDRESS", vm.toString(signer));
        vm.setEnv("POOL_MANAGER", "0x000000000004444c5dc75cB358380D2e3dE08A90");
    }

    function _assertClosed() internal view {
        assertFalse(d.hook.initialized());
        assertEq(d.hook.launchTimestamp(), 0);
        assertEq(d.token.balanceOf(address(d.hook)), 0);
        assertEq(d.token.balanceOf(signer), d.token.TOTAL_SUPPLY());
        assertEq(d.token.allowance(signer, address(d.launch)), d.token.TOTAL_SUPPLY());
        assertEq(d.token.totalBurned(), 0);
        assertEq(d.vault.rewardReserve(), 0);
        assertEq(d.v2.enabledFeatures(), 0);
        (uint160 price,,,) = manager.getSlot0(d.hook.poolId());
        assertEq(price, 0);
        assertEq(manager.getLiquidity(d.hook.poolId()), 0);
    }

    function test_deployLeavesTheMarketClosedAndSupplyWithDeployer() public configuredEnvironment {
        _assertClosed();
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonAddress(json, ".poolManager"), deployment.MAINNET_POOL_MANAGER());
        assertEq(vm.parseJsonAddress(json, ".teamAddress"), signer);
        assertFalse(vm.parseJsonBool(json, ".marketOpen"));
        assertFalse(vm.keyExistsJson(json, ".launchTimestamp"));
        assertFalse(vm.keyExistsJson(json, ".initialBuyWei"));
        launch.check(json, signer);
    }

    function test_strangerCannotInitializeDuringTheWaitThenDeployerLaunches() public configuredEnvironment {
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
        _assertClosed();
        (uint256 bought, string memory launched) = launch.open(json, signer);
        assertEq(bought, EXPECTED_BUY);
        assertTrue(d.hook.initialized());
        assertEq(d.hook.launchTimestamp(), 2_000_000);
        assertEq(d.token.balanceOf(signer), bought);
        assertEq(d.vault.rewardReserve(), 4_200_000e18);
        assertEq(d.v2.enabledFeatures(), 0);
        assertEq(vm.parseJsonUint(launched, ".initialBuyExpectedCubit"), bought);
        assertFalse(vm.parseJsonBool(launched, ".allowAnyPrice"));
        assertFalse(vm.parseJsonBool(launched, ".runtimeVerified"));
        assertEq(vm.parseJsonUint(launched, ".deployBlock"), 100);
        assertEq(vm.parseJsonUint(launched, ".launchBlock"), 200);
        assertEq(vm.parseJsonUint(launched, ".chainId"), 1);
        vm.expectRevert("market already open");
        launch.check(json, signer);
    }

    function test_previewUsesActualLaunchAndRestoresPoolSupplyAndBalances() public configuredEnvironment {
        uint256 balance = signer.balance;
        uint64 nonce = vm.getNonce(signer);
        (uint256 expected, bool allowAnyPrice) = launch.preview(json, signer);
        assertEq(expected, EXPECTED_BUY);
        assertFalse(allowAnyPrice);
        _assertClosed();
        assertEq(signer.balance, balance);
        assertEq(vm.getNonce(signer), nonce);
        assertEq(address(manager).balance, 0);
        assertEq(d.token.balanceOf(address(manager)), 0);
        assertEq(d.hook.teamAccrued(), 0);
        (uint256 repeated,) = launch.preview(json, signer);
        assertEq(repeated, expected);
        _assertClosed();
    }

    function test_previewFollowsTheDeployedPriceAndSelectedBuy() public configuredEnvironment {
        vm.setEnv("LAUNCH_FDV_WEI", "7500000000000000000");
        d = deployment.deploy(signer);
        json = deployment.manifest(d);
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "1");
        vm.setEnv("ALLOW_ANY_PRICE", "1");
        (uint256 expected,) = launch.preview(json, signer);
        assertGt(expected, 0);
        assertLt(expected, EXPECTED_BUY);
        _assertClosed();
        vm.setEnv("INITIAL_BUY_WEI", "200000000000000000");
        (uint256 larger,) = launch.preview(json, signer);
        assertGt(larger, expected);
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", vm.toString(larger));
        vm.setEnv("ALLOW_ANY_PRICE", "0");
        (uint256 bought,) = launch.open(json, signer);
        assertEq(bought, larger);
    }

    function test_failedDevBuyRollsBackPoolAndSupply() public configuredEnvironment {
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", vm.toString(d.token.TOTAL_SUPPLY()));
        vm.expectRevert(
            abi.encodeWithSelector(CubitRouter.TooLittleReceived.selector, EXPECTED_BUY, d.token.TOTAL_SUPPLY())
        );
        launch.open(json, signer);
        _assertClosed();
        assertEq(signer.balance, 10 ether);
    }

    function test_teamMustBeTheSignerAtDeploymentAndLaunch() public configuredEnvironment {
        vm.setEnv("TEAM_ADDRESS", vm.toString(makeAddr("other team")));
        vm.expectRevert("TEAM_ADDRESS must be the signer");
        deployment.deploy(signer);
        vm.expectRevert("TEAM_ADDRESS must be the signer");
        launch.check(json, signer);
        _assertClosed();
    }

    function test_wrongPoolManagerEnvironmentIsRefusedAtBothSteps() public configuredEnvironment {
        vm.setEnv("POOL_MANAGER", vm.toString(makeAddr("fake manager")));
        vm.expectRevert("POOL_MANAGER differs from canonical mainnet PoolManager");
        deployment.deploy(signer);
        vm.expectRevert("POOL_MANAGER differs from canonical mainnet PoolManager");
        launch.check(json, signer);
    }

    function test_manifestCannotSubstituteTheCanonicalManager() public configuredEnvironment {
        address fake = makeAddr("fake manager");
        vm.serializeJson("changed", json);
        string memory changed = vm.serializeAddress("changed", "poolManager", fake);
        vm.mockCall(address(d.hook), abi.encodeWithSignature("poolManager()"), abi.encode(fake));
        vm.expectRevert("noncanonical mainnet PoolManager");
        launch.check(changed, signer);
    }

    function test_bothEntrypointsRejectOtherChains() public configuredEnvironment {
        vm.chainId(11155111);
        vm.expectRevert("this release script is mainnet-only");
        deployment.run();
        vm.expectRevert("this release script is mainnet-only");
        launch.run();
    }

    function test_missingOrEmptyMinimumIsRefusedEvenWithOverride() public configuredEnvironment {
        // An empty environment value takes the same required-value branch as an absent variable.
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "");
        vm.setEnv("ALLOW_ANY_PRICE", "1");
        vm.expectRevert("INITIAL_BUY_MIN_CUBIT is required on mainnet");
        launch.preview(json, signer);
        _assertClosed();
    }

    function test_zeroMinimumIsRefusedEvenWithOverrideOrNoBuy() public configuredEnvironment {
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "0");
        vm.setEnv("ALLOW_ANY_PRICE", "1");
        vm.setEnv("INITIAL_BUY_WEI", "0");
        vm.expectRevert("INITIAL_BUY_MIN_CUBIT must be positive on mainnet");
        launch.preview(json, signer);
        _assertClosed();
    }

    function test_lowMinimumRequiresTheLiteralOverride() public configuredEnvironment {
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "1");
        string[4] memory rejected = [string(""), "0", "2", "true"];
        for (uint256 i; i < rejected.length; ++i) {
            vm.setEnv("ALLOW_ANY_PRICE", rejected[i]);
            vm.expectRevert("INITIAL_BUY_MIN_CUBIT below 99% of expected; set ALLOW_ANY_PRICE=1 to override");
            launch.preview(json, signer);
            _assertClosed();
        }
        vm.setEnv("ALLOW_ANY_PRICE", "1");
        (uint256 bought, string memory launched) = launch.open(json, signer);
        assertEq(bought, EXPECTED_BUY);
        assertTrue(vm.parseJsonBool(launched, ".allowAnyPrice"));
        assertEq(vm.parseJsonUint(launched, ".initialBuyMinCubit"), 1);
    }

    function test_minimumThresholdRoundsUpAndAcceptsItsBoundary() public configuredEnvironment {
        uint256 floor = FullMath.mulDivRoundingUp(EXPECTED_BUY, 9900, 10_000);
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", vm.toString(floor - 1));
        vm.expectRevert("INITIAL_BUY_MIN_CUBIT below 99% of expected; set ALLOW_ANY_PRICE=1 to override");
        launch.preview(json, signer);
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", vm.toString(floor));
        (uint256 bought,) = launch.open(json, signer);
        assertEq(bought, EXPECTED_BUY);
    }

    function test_noBuyStillRequiresAMinimumAndSeedsTheReserve() public configuredEnvironment {
        vm.setEnv("INITIAL_BUY_WEI", "0");
        vm.setEnv("INITIAL_BUY_MIN_CUBIT", "1");
        (uint256 expected,) = launch.preview(json, signer);
        assertEq(expected, 0);
        _assertClosed();
        (uint256 bought,) = launch.open(json, signer);
        assertEq(bought, 0);
        assertEq(d.vault.rewardReserve(), 4_200_000e18);
        assertTrue(d.hook.initialized());
    }

    function test_commonManifestAndWiringChecksStillApply() public configuredEnvironment {
        vm.serializeJson("changed", json);
        string memory changed = vm.serializeUint("changed", "chainId", 11155111);
        vm.expectRevert("manifest chain mismatch");
        launch.check(changed, signer);
        vm.serializeJson("changed", json);
        changed = vm.serializeUint("changed", "initialSqrtPriceX96", 1);
        vm.expectRevert("initial price mismatch");
        launch.check(changed, signer);
        vm.serializeJson("changed", json);
        changed = vm.serializeBytes32("changed", "poolId", bytes32(uint256(1)));
        vm.expectRevert("pool ID mismatch");
        launch.check(changed, signer);
        vm.mockCall(address(d.v2), abi.encodeWithSignature("moduleRevision()"), abi.encode(uint64(1)));
        vm.expectRevert("modules changed");
        launch.check(json, signer);
        vm.clearMockedCalls();
        vm.prank(signer);
        d.token.approve(address(d.launch), 0);
        vm.expectRevert("launch approval missing");
        launch.check(json, signer);
    }
}
