// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitToken} from "../src/CubitToken.sol";
import {CubitForge, CubitForgeToken} from "../src/periphery/CubitForge.sol";
import {CubitGovernanceVault} from "../src/periphery/CubitGovernanceVault.sol";

/// @notice A public child launch by any account, then one trading cycle on the child pool. The child hook is
///         deployed by CubitForge via CREATE2 with a salt bound to the launcher, so its address must carry the six hook
///         flags: the salt is mined here. The cycle checks that a child, which has no vault, sends what its crossed walls
///         absorb to the launchpad governance vault. Run after LaunchpadDeploy.s.sol and the team's activate(8):
///           DEPLOYMENT=deployments/31337.local.candidate.json LAUNCHPAD=deployments/31337.launchpad.candidate.json \
///             forge script script/ForgeLaunch.s.sol --rpc-url anvil --broadcast --private-key <any funded key>
///         Off Anvil, CHILD_TEAM (the address that receives the child's taxes) is required, and CHILD_BUY_WEI sets the
///         buy of the trading cycle (default 1 ETH on Anvil, 0.05 ETH elsewhere).
contract ForgeLaunch is Script {
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(vm.readFile(vm.envString("DEPLOYMENT")), ".hook")));
        CubitForge forge = CubitForge(vm.parseJsonAddress(vm.readFile(vm.envString("LAUNCHPAD")), ".forge"));
        CubitGovernanceVault governance = CubitGovernanceVault(forge.governanceVault());
        uint256 fee = forge.launchFee();
        address launcher = msg.sender;
        // On Anvil the child's taxes go to a known test account; anywhere else the launcher names a team it controls.
        address childTeam = block.chainid == 31337
            ? vm.envOr("CHILD_TEAM", address(0x976EA74026E726554dB657fA54763abd0C3a0aa9)) // Anvil #6
            : vm.envAddress("CHILD_TEAM");
        string memory name_ = "Child CUBIT";
        string memory symbol_ = "cCUBIT";
        bytes32 tokenSalt = bytes32(vm.envOr("TOKEN_SALT", uint256(1)));

        address predictedToken = vm.computeCreate2Address(
            keccak256(abi.encode(launcher, tokenSalt)),
            keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode(name_, symbol_))),
            address(forge)
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CubitHook).creationCode, abi.encode(hook.poolManager(), predictedToken, childTeam, hook.LAUNCH_ETH())
            )
        );
        (address predictedHook, bytes32 hookSalt) = _mineHookSalt(launcher, initCodeHash, address(forge));

        address eth = governance.ETH();
        uint256 floorBefore = hook.pendingFloorEth();
        uint256 feesBefore = governance.held(eth);
        uint256 launchesBefore = forge.launches();

        vm.startBroadcast();
        (address childToken, address childHook) =
            forge.launch{value: fee}(name_, symbol_, childTeam, tokenSalt, hookSalt, type(CubitHook).creationCode);
        vm.stopBroadcast();

        require(childToken == predictedToken, "token addr mismatch");
        require(childHook == predictedHook, "hook addr mismatch");
        require(forge.launches() == launchesBefore + 1, "launches not incremented");
        require(hook.pendingFloorEth() == floorBefore, "the launch touched the parent's wall funds");
        require(governance.held(eth) == feesBefore + fee, "fee not locked in the governance vault");
        (uint256 feeLocked, uint256 feeUnlockAt) = governance.tranche(eth, governance.trancheCount(eth) - 1);
        require(
            feeLocked == fee && feeUnlockAt == block.timestamp + governance.LOCK_DURATION() + governance.lockExtension(),
            "fee not locked for the vault's lock"
        );
        require(CubitHook(payable(childHook)).initialized(), "child not initialized");

        console2.log("launcher  ", launcher);
        console2.log("childToken", childToken);
        console2.log("childHook ", childHook);
        console2.log("launch fee locked in the governance vault (wei)", governance.held(eth) - feesBefore);
        console2.log("OK public child launch");

        _childWallsToGovernance(CubitHook(payable(childHook)), governance);
    }

    /// @dev The hook salt the Forge will bind to `launcher`, such that the child hook's CREATE2 address carries the flags.
    function _mineHookSalt(address launcher, bytes32 initCodeHash, address forge)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        for (uint256 i; i < 1_000_000; i++) {
            salt = bytes32(i);
            hookAddress = vm.computeCreate2Address(keccak256(abi.encode(launcher, salt)), initCodeHash, forge);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == FLAGS && hookAddress.code.length == 0) return (hookAddress, salt);
        }
        revert("no hook salt found");
    }

    /// @dev Buy on the child pool, sell a tenth to place a wall, sell the rest back through it with a route
    ///      that does not deliver, then deliver publicly: the governance vault books the child's CUBIT as one
    ///      tranche locked for the vault's lock.
    function _childWallsToGovernance(CubitHook child, CubitGovernanceVault governance) internal {
        PoolKey memory key = child.poolKey();
        CubitToken childToken = child.token();
        require(child.absorbedTokenSink() == address(governance), "child sink is not the governance vault");
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint256 buy = vm.envOr("CHILD_BUY_WEI", block.chainid == 31337 ? uint256(1 ether) : uint256(0.05 ether));

        vm.startBroadcast();
        PoolSwapTest raw = new PoolSwapTest(child.poolManager());
        childToken.approve(address(raw), type(uint256).max);
        raw.swap{value: buy}(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(buy), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings, ""
        );
        uint256 bought = childToken.balanceOf(msg.sender);
        raw.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(bought / 10), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            settings, ""
        );
        require(child.activeWallCount() == 1, "child sale placed no wall");
        uint256 firstWall = child.latestWallId();
        raw.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(bought - bought / 10), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            settings, ""
        );
        (, uint128 firstWallLiquidity,,) = child.walls(firstWall);
        uint256 absorbed = child.pendingAbsorbedTokens();
        require(firstWallLiquidity == 0 && absorbed != 0, "the child's crossed wall was not emptied");
        uint256 held0 = governance.held(address(childToken));
        child.deliverAbsorbed();
        vm.stopBroadcast();

        require(governance.held(address(childToken)) - held0 == absorbed, "governance vault did not book the child's CUBIT");
        (uint256 amount, uint256 unlockAt) =
            governance.tranche(address(childToken), governance.trancheCount(address(childToken)) - 1);
        require(
            amount == absorbed && unlockAt == block.timestamp + governance.LOCK_DURATION() + governance.lockExtension(),
            "tranche not locked for the vault's lock"
        );
        console2.log("child crossed wall -> governance vault, CUBIT", absorbed);
        console2.log("   tranche unlocks at", unlockAt);
        console2.log("OK child walls -> governance vault");
    }
}
