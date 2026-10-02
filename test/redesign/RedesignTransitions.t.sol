// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LensReads} from "../utils/LensReads.sol";

import {console2} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {RedesignBase} from "./utils/RedesignBase.sol";
import {CubitHook} from "../../src/CubitHook.sol";
import {CubitToken} from "../../src/CubitToken.sol";
import {CubitLens} from "../../src/CubitLens.sol";
import {ICubitLens} from "../../src/interfaces/ICubitLens.sol";
import {CubitRouter} from "../../src/periphery/CubitRouter.sol";
import {CubitVault} from "../../src/periphery/CubitVault.sol";
import {CubitV2} from "../../src/periphery/CubitV2.sol";
import {CubitForge, CubitForgeToken} from "../../src/periphery/CubitForge.sol";

/// @dev A replacement vault that passes every registry check but refuses reward funding: an honest deployment mistake
///      or a hostile module registered by the team.
contract RefusingVault {
    address public immutable hook;
    address public immutable token;
    uint256 public totalStaked;
    uint256 public rewardReserve;

    constructor(address hook_, address token_) {
        hook = hook_;
        token = token_;
    }

    function fundRewardReserve(uint256) external pure {
        revert("vault refuses funding");
    }
}

/// @notice One deployment, a living release, then every registry feature opened from that same deployment by an explicit
///         team transaction: no date to wait for, and nothing that opens by itself. The vault and the Momentum lens
///         come with the launch; the public launchpad is deployed and registered after it. Each feature is refused to
///         anyone but the team, used for real once open, with trading replayed after each step. Branches: a release that
///         never opens anything, activations in any order at any time, module replacements with engaged users, a
///         launchpad v2 with a living child, public launches that neither invalidate nor steal each other, a replacement
///         vault that refuses funding, a foreign registry.
contract RedesignTransitionsTest is RedesignBase {
    uint8 internal constant VAULT = 1;
    uint8 internal constant REMOVED_REFERRAL_BIT = 2; // the referral feature was removed: bit 2 never opens
    uint8 internal constant MOMENTUM = 4;
    uint8 internal constant FORGE = 8;
    uint8 internal constant ALL_FEATURES = VAULT | MOMENTUM | FORGE;
    address internal constant ETH_KEY = address(0); // the governance vault books ETH under address zero

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev The addresses a launch will use and the salts that give them.
    struct Launch {
        bytes32 tokenSalt;
        bytes32 hookSalt;
        address token;
        address hook;
    }

    // ------------------------------------------------------------------ the nominal sequence

    function test_nominalSequence_everyFeatureOpensFromTheLivingRelease() public {
        _replay("launch");
        _closedModulesRefuse();
        assertEq(registry.forge(), address(0), "a launchpad is registered at launch");

        _open(VAULT);
        _useVault("vault");
        _replay("after the vault");

        _open(MOMENTUM);
        _useMomentum("momentum");
        _useVault("vault still open");
        _replay("after momentum");

        // The launchpad arrives after the launch: registered, still closed, then opened by the team.
        _deployLaunchpad();
        assertEq(registry.enabledFeatures() & FORGE, 0, "registering the launchpad opened it");
        _open(FORGE);
        address child = _useForge(alice, "a trader launches");
        _useForge(team, "the team launches too");
        _useMomentum("momentum still open");
        _useVault("vault still open");
        _replay("after the launchpad");
        assertEq(registry.enabledFeatures(), ALL_FEATURES, "every feature is open after the three openings");

        // A Lens replacement clears only its own bit; the other modules and the children keep working.
        CubitLens next = new CubitLens(hook);
        uint256 revision = registry.moduleRevision();
        vm.prank(team);
        registry.setLens(address(next));
        assertEq(registry.moduleRevision(), revision + 1);
        assertEq(registry.enabledFeatures(), ALL_FEATURES ^ MOMENTUM, "only the Momentum bit falls back to zero");
        _useVault("after the lens replacement");
        assertTrue(CubitHook(payable(child)).initialized(), "the child did not survive the parent's module changes");
        vm.prank(team);
        registry.activate(MOMENTUM);
        _useMomentum("new lens");
        _replay("end");

        // Both launch fees unlock after their month, and only the governance vault's deployer receives them.
        vm.warp(block.timestamp + 30 days);
        uint256 balance0 = address(this).balance;
        assertEq(governanceVault.claim(ETH_KEY, type(uint256).max), 2 * forge.launchFee(), "the launch fees did not unlock");
        assertEq(address(this).balance - balance0, 2 * forge.launchFee());
    }

    // ------------------------------------------------------------------ the public launchpad

    /// The release launches without a launchpad; the team registers one later, and it stays closed until the team opens
    /// it, the very day of the launch if it wants.
    function test_launchpad_absentAtLaunchRegisteredLaterOpenedOnlyByTheTeam() public {
        assertEq(registry.forge(), address(0));
        vm.prank(team);
        vm.expectRevert(CubitV2.NotReady.selector);
        registry.activate(FORGE);

        _deployLaunchpad();
        assertEq(registry.forge(), address(forge));
        assertEq(registry.enabledFeatures(), 0, "registering the launchpad opened something");
        uint256 fee = forge.launchFee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Forge inactive"));
        forge.launch{value: fee}("X", "X", alice, bytes32(0), bytes32(0), type(CubitHook).creationCode);
        vm.prank(alice);
        vm.expectRevert(CubitV2.NotAuthority.selector);
        registry.activate(FORGE);

        vm.prank(team);
        registry.activate(FORGE); // the launch day: no date to wait for
        assertEq(registry.enabledFeatures(), FORGE);
        _useForge(alice, "opened the launch day");
    }

    /// Two traders launch in the same block with salts mined in advance: neither launch invalidates the other, since a
    /// child token's address does not depend on how many launches came first.
    function test_launchpad_launchesInOneBlockDoNotInvalidateEachOther() public {
        _openLaunchpad();
        Launch memory a = _mine(alice, "Alpha", "ALPHA", alice, bytes32(uint256(1)));
        Launch memory b = _mine(bob, "Beta", "BETA", bob, bytes32(uint256(1)));
        uint256 fee = forge.launchFee();
        vm.deal(alice, fee);
        vm.deal(bob, fee);
        vm.prank(bob);
        (address tokenB, address hookB) =
            forge.launch{value: fee}("Beta", "BETA", bob, b.tokenSalt, b.hookSalt, type(CubitHook).creationCode);
        vm.prank(alice);
        (address tokenA, address hookA) =
            forge.launch{value: fee}("Alpha", "ALPHA", alice, a.tokenSalt, a.hookSalt, type(CubitHook).creationCode);
        assertEq(tokenA, a.token, "alpha token address");
        assertEq(hookA, a.hook, "alpha hook address");
        assertEq(tokenB, b.token, "beta token address");
        assertEq(hookB, b.hook, "beta hook address");
        assertTrue(CubitHook(payable(hookA)).initialized() && CubitHook(payable(hookB)).initialized());
        assertEq(forge.launches(), 2);
    }

    /// Salts copied from another launcher's pending launch give other addresses: the copy cannot take that launch, its
    /// hook address lacks the flags so it fails, and the original launch still goes through.
    function test_launchpad_copiedSaltsCannotTakeALaunch() public {
        _openLaunchpad();
        Launch memory a = _mine(alice, "Alpha", "ALPHA", alice, bytes32(uint256(7)));
        uint256 fee = forge.launchFee();
        vm.deal(carol, fee);
        vm.prank(carol);
        vm.expectRevert(bytes("child deployment failed"));
        forge.launch{value: fee}("Alpha", "ALPHA", alice, a.tokenSalt, a.hookSalt, type(CubitHook).creationCode);
        vm.deal(alice, fee);
        vm.prank(alice);
        (address token_, address hook_) =
            forge.launch{value: fee}("Alpha", "ALPHA", alice, a.tokenSalt, a.hookSalt, type(CubitHook).creationCode);
        assertEq(token_, a.token);
        assertEq(hook_, a.hook);
    }

    /// The app reuses the salts of a launch it has not seen confirmed, and this is why: sending the same launch twice
    /// collides with the child token's CREATE2 address and reverts, instead of launching a twin and paying a second
    /// launch fee that governance never refunds.
    function test_launchpad_theSameSaltsCannotLaunchTwice() public {
        _openLaunchpad();
        Launch memory a = _mine(alice, "Alpha", "ALPHA", alice, bytes32(uint256(11)));
        uint256 fee = forge.launchFee();
        vm.deal(alice, 2 * fee);
        vm.prank(alice);
        (address token_, address hook_) =
            forge.launch{value: fee}("Alpha", "ALPHA", alice, a.tokenSalt, a.hookSalt, type(CubitHook).creationCode);
        assertEq(token_, a.token);
        assertEq(hook_, a.hook);
        vm.prank(alice);
        vm.expectRevert();
        forge.launch{value: fee}("Alpha", "ALPHA", alice, a.tokenSalt, a.hookSalt, type(CubitHook).creationCode);
        assertEq(forge.launches(), 1, "a second send launched a twin token");
        assertEq(alice.balance, fee, "the second launch fee left the launcher");
    }

    /// A launchpad v2 replaces the module: the living child keeps trading, the v2 stays closed until the team opens it,
    /// the retired launchpad cannot launch again, and the v2 launches with its own fee.
    function test_branch_launchpadV2KeepsChildren() public {
        _openLaunchpad();
        address child = _useForge(alice, "launchpad v1");
        CubitForge v1 = forge;
        CubitForge v2Forge = new CubitForge(hook, 0.02 ether, address(governanceVault));
        vm.prank(team);
        registry.setForge(address(v2Forge));
        assertEq(registry.enabledFeatures() & FORGE, 0, "the forge bit is not cleared");
        assertTrue(CubitHook(payable(child)).initialized(), "an existing child was touched");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("Forge inactive"));
        v2Forge.launch{value: 0.02 ether}("Y", "Y", bob, bytes32(0), bytes32(0), type(CubitHook).creationCode);
        vm.prank(team);
        registry.activate(FORGE);
        vm.prank(bob);
        vm.expectRevert(bytes("Forge inactive"));
        v1.launch{value: 0.01 ether}("Z", "Z", bob, bytes32(0), bytes32(0), type(CubitHook).creationCode);
        forge = v2Forge;
        _useForge(bob, "launchpad v2");
        _replay("after the launchpad v2");

        CubitHook old = CubitHook(payable(child));
        // Read the key before the prank: an external read in the arguments would consume it.
        PoolKey memory oldKey = old.poolKey();
        vm.deal(carol, 0.1 ether);
        vm.prank(carol);
        swapRouter.swap{value: 0.1 ether}(
            oldKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(old.token().balanceOf(carol), 0, "the launchpad v1 child no longer trades");
    }

    // ------------------------------------------------------------------ branches

    /// Kept for a year with every module closed: nothing opens by itself, closed entry points refuse, reads and trading
    /// keep working, and crossed walls still fund the registered vault's reserve.
    function test_branch_nothingOpensByItself() public {
        uint256 reserve0 = vault.rewardReserve();
        _replay("launch");
        assertGt(vault.rewardReserve(), reserve0, "delivery to the reserve needs a flag");
        vm.warp(START + 400 days);
        vm.roll(block.number + 100_000);
        assertEq(registry.enabledFeatures(), 0);
        _closedModulesRefuse();
        _useMomentum("reads never depend on a flag");
        _replay("+400 days");
    }

    /// Activations in any order at any time: all three on the launch day in reverse order, or a single one a year later.
    function test_branch_activationsInAnyOrderAtAnyTime() public {
        _replay("launch");
        uint256 base = vm.snapshotState();

        _deployLaunchpad();
        vm.startPrank(team);
        registry.activate(FORGE);
        registry.activate(MOMENTUM);
        registry.activate(VAULT);
        vm.stopPrank();
        assertEq(registry.enabledFeatures(), ALL_FEATURES);
        _useForge(bob, "all on the launch day");
        _useMomentum("all on the launch day");
        _useVault("all on the launch day");
        _replay("all on the launch day");

        vm.revertToState(base);
        vm.warp(START + 365 days);
        vm.prank(team);
        registry.activate(MOMENTUM);
        assertEq(registry.enabledFeatures(), MOMENTUM);
        _useMomentum("a year later, vault skipped");
        vm.expectRevert(CubitVault.Inactive.selector);
        vault.stake(1);
        _replay("vault skipped");
    }

    /// Replacements with engaged users. A vault rotation with a staker inside: the retired vault keeps the stake, its
    /// accrual and its exits, refuses deposits even once the bit re-opens, and crossed walls fund the new reserve. A
    /// router rotation changes no feature, and the retired and the new router both pay the whole team share.
    function test_branch_replacementsWithEngagedUsers() public {
        _replay("launch");
        vm.startPrank(team);
        registry.activate(VAULT);
        registry.activate(MOMENTUM);
        vm.stopPrank();

        uint256 held = _buy(alice, 0.3 ether);
        uint256 balance0 = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(vault), held);
        vault.stake(held);
        vm.stopPrank();

        CubitVault replacement = new CubitVault(hook);
        vm.prank(team);
        registry.setVault(address(replacement));
        assertEq(registry.enabledFeatures() & VAULT, 0, "the vault bit is not cleared");
        assertEq(registry.enabledFeatures() & MOMENTUM, MOMENTUM, "the momentum bit changed");
        assertEq(registry.vaultCount(), 2);
        assertEq(hook.absorbedTokenSink(), address(replacement), "absorbed CUBIT do not go to the new vault");
        vm.startPrank(alice);
        vm.expectRevert(CubitVault.Inactive.selector);
        vault.stake(1);
        vm.expectRevert(CubitVault.Inactive.selector);
        replacement.stake(1);
        vm.stopPrank();

        uint256 retiredReserve = vault.rewardReserve();
        uint256 absorbed = _crossWall(bob, true);
        assertGt(absorbed, 0, "no wall was crossed");
        assertEq(replacement.rewardReserve(), absorbed, "the new reserve did not receive the absorbed CUBIT");
        assertEq(vault.rewardReserve(), retiredReserve, "the retired reserve moved");
        assertEq(lens.rewardReserve(), retiredReserve + absorbed, "the Lens does not add both reserves");

        vm.warp(START + 1 days);
        uint256 due = vault.pendingCubit(alice);
        assertEq(due, held * 300 / 10_000, "the retired vault stopped accruing");
        vm.prank(alice);
        vault.withdraw(held);
        assertEq(token.balanceOf(alice), balance0 + due, "principal and reward did not come back from the retired vault");

        vm.prank(team);
        registry.activate(VAULT);
        vm.startPrank(alice);
        vm.expectRevert(CubitVault.Inactive.selector);
        vault.stake(1);
        token.approve(address(replacement), held / 2);
        replacement.stake(held / 2);
        vm.stopPrank();
        assertEq(replacement.totalStaked(), held / 2, "new deposits did not go to the registered vault");
        assertEq(vault.totalStaked(), 0);

        CubitRouter newRouter = new CubitRouter(manager, hook);
        uint8 features = registry.enabledFeatures();
        uint256 revision = registry.moduleRevision();
        vm.prank(team);
        registry.setRouter(address(newRouter));
        assertEq(registry.router(), address(newRouter));
        assertEq(registry.enabledFeatures(), features, "a router replacement changed a feature");
        assertEq(registry.moduleRevision(), revision + 1);
        uint256 team0 = hook.teamAccrued();
        vm.deal(carol, carol.balance + 0.2 ether);
        vm.prank(carol);
        router.swapExactIn{value: 0.1 ether}(key, true, 0.1 ether, 0, carol, type(uint256).max);
        assertEq(hook.teamAccrued() - team0, 0.003 ether, "the retired router does not pay the whole team share");
        vm.prank(carol);
        newRouter.swapExactIn{value: 0.1 ether}(key, true, 0.1 ether, 0, carol, type(uint256).max);
        assertEq(hook.teamAccrued() - team0, 0.006 ether, "the new router does not pay the whole team share");
        _replay("after the rotations");
    }

    /// A registered vault that refuses funding cannot block trading: the canonical router's delivery is best effort,
    /// the absorbed CUBIT wait in the hook as claims, and the next honest vault receives every one of them.
    function test_branch_refusingVaultNeverBlocksTradingAndIsRecoverable() public {
        RefusingVault refusing = new RefusingVault(address(hook), address(token));
        vm.prank(team);
        registry.setVault(address(refusing)); // its getters pass: the registry cannot tell
        uint256 absorbed = _crossWall(bob, false);
        assertGt(absorbed, 0, "no wall was crossed");
        vm.expectRevert(bytes("vault refuses funding"));
        hook.deliverAbsorbed();
        assertEq(hook.pendingAbsorbedTokens(), absorbed, "the absorbed CUBIT did not wait in the hook");

        uint256 got = _buy(alice, 10 ether);
        _sell(alice, got / 10);
        _sell(alice, got - got / 10);
        assertGe(hook.pendingAbsorbedTokens(), absorbed);
        _assertBooks();
        _assertNoCrossedWall();

        CubitVault honest = new CubitVault(hook);
        vm.prank(team);
        registry.setVault(address(honest));
        uint256 waiting = hook.pendingAbsorbedTokens();
        hook.deliverAbsorbed();
        assertEq(honest.rewardReserve(), waiting, "the honest vault did not receive what waited");
        assertEq(hook.pendingAbsorbedTokens(), 0);
        assertEq(lens.rewardReserve(), vault.rewardReserve() + honest.rewardReserve(), "the Lens reserves");
        _assertBooks();
    }

    /// A registry the hook was not configured with opens nothing, its vault takes no stake, and the hook's anchor is
    /// frozen.
    function test_branch_foreignRegistryOpensNothing() public {
        CubitVault foreignVault = new CubitVault(hook);
        CubitV2 foreign = new CubitV2(hook, address(foreignVault), address(router), address(0), address(lens));
        vm.prank(team);
        vm.expectRevert(CubitV2.NotReady.selector);
        foreign.activate(VAULT);
        vm.expectRevert(CubitVault.Inactive.selector);
        foreignVault.stake(1);
        vm.expectRevert(CubitHook.InvalidV2.selector);
        hook.configureV2(address(foreign));
        assertEq(hook.v2(), address(registry));
    }

    // ------------------------------------------------------------------ uses

    /// @dev Nothing is open at launch and nothing opens by itself: no stake, no unknown feature, no removed referral
    ///      feature, and no launchpad to open before one is registered.
    function _closedModulesRefuse() internal {
        vm.expectRevert(CubitVault.Inactive.selector);
        vault.stake(1);
        vm.prank(team);
        vm.expectRevert(CubitV2.InvalidFeature.selector);
        registry.activate(REMOVED_REFERRAL_BIT);
        vm.prank(team);
        vm.expectRevert(CubitV2.InvalidFeature.selector);
        registry.activate(16);
        if (registry.forge() == address(0)) {
            vm.prank(team);
            vm.expectRevert(CubitV2.NotReady.selector);
            registry.activate(FORGE);
        }
    }

    /// @dev Refused to anyone but the team, then opened once, at any time.
    function _open(uint8 feature) internal {
        vm.prank(alice);
        vm.expectRevert(CubitV2.NotAuthority.selector);
        registry.activate(feature);
        vm.prank(team);
        registry.activate(feature);
        assertTrue(registry.enabledFeatures() & feature != 0, "the feature did not open");
        vm.prank(team);
        vm.expectRevert(CubitV2.AlreadyActive.selector);
        registry.activate(feature);
    }

    function _openLaunchpad() internal {
        _deployLaunchpad();
        vm.prank(team);
        registry.activate(FORGE);
    }

    /// @dev The release keeps trading: a buy, a partial sale that places a wall, the rest sold back; books exact.
    function _replay(string memory stage) internal {
        uint256 got = _buy(bob, 0.2 ether);
        _sell(bob, got / 10);
        _sell(bob, got - got / 10);
        _assertBooks();
        _assertNoCrossedWall();
        assertEq(hook.pendingAbsorbedTokens(), 0, "the router did not deliver the absorbed CUBIT");
        console2.log(string.concat("trading ok: ", stage));
    }

    /// @dev A stake in the registered vault earns 3% in a day and comes back in full.
    function _useVault(string memory stage) internal {
        CubitVault v = CubitVault(registry.vault());
        uint256 amount = _buy(alice, 0.3 ether);
        uint256 balance0 = token.balanceOf(alice) - amount;
        vm.startPrank(alice);
        token.approve(address(v), amount);
        v.stake(amount);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        uint256 due = v.pendingCubit(alice);
        assertEq(due, amount * 300 / 10_000, "not 3% after a day");
        vm.prank(alice);
        v.withdraw(amount);
        assertEq(token.balanceOf(alice), balance0 + amount + due, "principal and reward did not come back");
        console2.log(string.concat("vault ok: ", stage));
    }

    /// @dev Read-only: the registered Lens serves the same figures as the hook and the release Lens at this block.
    function _useMomentum(string memory stage) internal view {
        CubitLens registered = CubitLens(registry.lens());
        ICubitLens.Snapshot memory s = registered.snapshot();
        assertEq(s.blockNumber, block.number);
        assertEq(s.totalSupply, token.totalSupply());
        assertEq(LensReads.wallEth(registered), LensReads.wallEth(lens));
        assertEq(LensReads.wallTokens(registered), LensReads.wallTokens(lens));
        assertEq(LensReads.circulatingSupply(registered), LensReads.circulatingSupply(lens));
        assertEq(LensReads.heldSupply(registered), LensReads.heldSupply(lens));
        assertEq(s.rewardReserve, lens.rewardReserve());
        assertEq(s.pendingFloorEth, hook.pendingFloorEth());
        assertEq(s.teamAccrued, hook.teamAccrued());
        assertEq(s.pendingAbsorbedTokens, hook.pendingAbsorbedTokens());
        assertEq(s.activeWallCount, hook.activeWallCount());
        assertEq(s.bestWallPrice, lens.bestWallPrice());
        console2.log(string.concat("momentum ok: ", stage));
    }

    /// @dev Anyone launches a child with the frozen template and salts bound to itself; the fee is locked in the
    ///      governance vault and the parent's walls are untouched; the child trades on its own books and its crossed
    ///      wall goes to the governance vault too.
    function _useForge(address launcher, string memory stage) internal returns (address child) {
        uint256 fee = forge.launchFee();
        Launch memory l = _mine(launcher, "Child", "CHLD", launcher, bytes32(forge.launches() + 1));
        vm.deal(launcher, launcher.balance + fee + 1);
        vm.prank(launcher);
        vm.expectRevert(bytes("wrong launch fee"));
        forge.launch{value: fee + 1}("Child", "CHLD", launcher, l.tokenSalt, l.hookSalt, type(CubitHook).creationCode);

        uint256 pending = hook.pendingFloorEth();
        uint256 fees0 = governanceVault.held(ETH_KEY);
        vm.prank(launcher);
        address childToken;
        (childToken, child) =
            forge.launch{value: fee}("Child", "CHLD", launcher, l.tokenSalt, l.hookSalt, type(CubitHook).creationCode);
        assertEq(childToken, l.token, "child token address");
        assertEq(child, l.hook, "child hook address");
        assertEq(hook.pendingFloorEth(), pending, "the launch touched the parent's wall funds");
        assertEq(governanceVault.held(ETH_KEY) - fees0, fee, "the fee is not locked in the governance vault");
        (uint256 feeLocked, uint256 feeUnlockAt) =
            governanceVault.tranche(ETH_KEY, governanceVault.trancheCount(ETH_KEY) - 1);
        assertEq(feeLocked, fee);
        assertEq(feeUnlockAt, block.timestamp + 30 days, "the fee is not locked for 30 days");
        CubitHook c = CubitHook(payable(child));
        assertTrue(c.initialized());
        assertEq(c.v2(), address(0), "a child has a registry");
        assertEq(c.TEAM_ADDRESS(), launcher, "the child team is not the one given at launch");
        assertEq(c.absorbedTokenSink(), address(governanceVault), "a child's sink is not the governance vault");

        CubitToken ct = CubitToken(childToken);
        PoolKey memory ck = c.poolKey();
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.deal(bob, bob.balance + 1 ether);
        vm.startPrank(bob);
        ct.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap{value: 1 ether}(
            ck,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ""
        );
        uint256 got = ct.balanceOf(bob);
        swapRouter.swap(
            ck,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got / 10), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            settings,
            ""
        );
        swapRouter.swap(
            ck,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(got - got / 10), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        vm.stopPrank();
        uint256 absorbed = c.pendingAbsorbedTokens();
        assertGt(absorbed, 0, "the child's crossed wall was not emptied");
        uint256 held0 = governanceVault.held(childToken);
        c.deliverAbsorbed();
        assertEq(governanceVault.held(childToken) - held0, absorbed, "the governance vault did not book the child's CUBIT");
        (uint256 amount, uint256 unlockAt) =
            governanceVault.tranche(childToken, governanceVault.trancheCount(childToken) - 1);
        assertEq(amount, absorbed);
        assertEq(unlockAt, block.timestamp + 30 days, "the child's CUBIT are not locked for 30 days");
        assertEq(hook.pendingFloorEth(), pending, "the child's trades touched the parent");
        console2.log(string.concat("forge ok: ", stage));
    }

    /// @dev The addresses a launch by `launcher` will use: the token from its bound token salt, and a hook salt, bound
    ///      to the launcher too, that gives the hook address the six flags.
    function _mine(address launcher, string memory name_, string memory symbol_, address childTeam, bytes32 tokenSalt)
        internal
        view
        returns (Launch memory l)
    {
        l.tokenSalt = tokenSalt;
        l.token = vm.computeCreate2Address(
            keccak256(abi.encode(launcher, tokenSalt)),
            keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode(name_, symbol_))),
            address(forge)
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CubitHook).creationCode, abi.encode(manager, l.token, childTeam, hook.LAUNCH_ETH()))
        );
        for (uint256 i; i < 1_000_000; i++) {
            address candidate = vm.computeCreate2Address(keccak256(abi.encode(launcher, bytes32(i))), initCodeHash, address(forge));
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == FLAGS && candidate.code.length == 0) {
                (l.hookSalt, l.hook) = (bytes32(i), candidate);
                return l;
            }
        }
        revert("no hook salt");
    }

    /// @dev Pump, place a wall with a small sale, then sell down through it with a price-limited route: the wall is fully
    ///      crossed and emptied. Returns the CUBIT it absorbed, delivered through the public entry point if asked.
    function _crossWall(address who, bool deliver) internal returns (uint256 absorbed) {
        uint256 got = _buy(who, 10 ether);
        _sell(who, got / 10);
        (int24 lower,,,) = hook.walls(hook.latestWallId());
        _rawSell(who, token.balanceOf(who), TickMath.getSqrtPriceAtTick(lower + hook.TICK_SPACING()));
        absorbed = hook.pendingAbsorbedTokens();
        if (deliver) hook.deliverAbsorbed();
    }
}
