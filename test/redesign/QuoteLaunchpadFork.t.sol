// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CubitHook} from "../../src/CubitHook.sol";
import {CubitV2} from "../../src/periphery/CubitV2.sol";
import {CubitRouter} from "../../src/periphery/CubitRouter.sol";
import {CubitForge} from "../../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../../src/periphery/CubitForgeV2.sol";
import {CubitGovernanceVault} from "../../src/periphery/CubitGovernanceVault.sol";
import {CubitQuoteHook} from "../../src/quote/CubitQuoteHook.sol";
import {QuoteLaunchpadTest} from "./QuoteLaunchpad.t.sol";
import {CubitForgeToken} from "../../src/periphery/CubitForge.sol";

/// @notice The launchpad v2 suite again, on a fork of Ethereum mainnet: the canonical PoolManager and the real USDC,
///         USDT, WBTC and Ondo tokenized stocks (NVDAon, SPCXon, TSLAon, AAPLon, GOOGLon), with their proxies, their
///         blocklists and Ondo's compliance and pause checks on every transfer. A fresh CUBIT release is deployed on
///         the fork; nothing leaves it. Skipped unless FORK_BLOCK is set; the RPC URL is read from MAINNET_RPC_URL
///         inside the test, never passed on a command line:
///           FORK_BLOCK=<block> FOUNDRY_FUZZ_RUNS=8 forge test --match-contract QuoteLaunchpadForkTest
contract QuoteLaunchpadForkTest is QuoteLaunchpadTest {
    using SafeERC20 for IERC20;

    address internal constant CANONICAL_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant NVDAON = 0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE;
    address internal constant SPCXON = 0xc9eef266834730340A55B6CC24621B31BAF55581;
    address internal constant AAPLON = 0x14c3abF95Cb9C93a8b82C1CdCB76D72Cb87b2d4c;
    address internal constant GOOGLON = 0xbA47214eDd2bb43099611b208f75E4b42FDcfEDc;

    function setUp() public override {
        if (vm.envOr("FORK_BLOCK", uint256(0)) == 0) vm.skip(true);
        super.setUp();
    }

    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("MAINNET_RPC_URL", CANONICAL_POOL_MANAGER);
    }

    function _setUpQuotes() internal override {}

    function _quotes() internal view override returns (address[] memory q) {
        q = new address[](9);
        (q[0], q[1], q[2], q[3], q[4]) = (ETH, USDC, USDT, WBTC, TSLAON);
        (q[5], q[6], q[7], q[8]) = (NVDAON, SPCXON, AAPLON, GOOGLON);
    }

    /// @dev Illustrative values of the order of 3.75 ETH; the deployment's table is set from prices on its day.
    function _values() internal pure override returns (uint256[] memory v) {
        v = new uint256[](9);
        (v[0], v[1], v[2], v[3], v[4]) = (3.75 ether, 15_000e6, 15_000e6, 0.15e8, 35e18);
        (v[5], v[6], v[7], v[8]) = (80e18, 50e18, 60e18, 60e18);
    }

    function _mintQuote(address quote, address to, uint256 amount) internal override {
        if (quote == ETH) vm.deal(to, to.balance + amount);
        else deal(quote, to, IERC20(quote).balanceOf(to) + amount);
    }

    function _approve(address quote, address owner, address spender) internal override {
        if (quote == ETH) return;
        vm.startPrank(owner);
        IERC20(quote).forceApprove(spender, type(uint256).max);
        vm.stopPrank();
    }

    // ================================================================== real-token behaviour

    address internal constant ONDO_PAUSE_MANAGER = 0xfD48112E448417CA79305a518c4186dF4b0A200a;

    function _pauseOndo(address token_, bool paused) internal {
        vm.mockCall(ONDO_PAUSE_MANAGER, abi.encodeWithSignature("isTokenPaused(address)", token_), abi.encode(paused));
    }

    /// @dev A paused Ondo quote stops every path that moves the token, but a route that nets
    ///      the quote inside the PoolManager (child A -> TSLAon -> child B) never calls it and still goes through.
    function test_OndoPauseStopsTransfersNotNettedRoutes() public {
        (Child memory a,) = _launch(alice, TSLAON, 0);
        (Child memory b,) = _launch(bob, TSLAON, 0);
        uint256 got = _buyChild(a, bob, 5e18);
        _pauseOndo(TSLAON, true);
        _mintQuote(TSLAON, bob, 1e18); // deal writes storage: no transfer, no pause check
        vm.prank(bob);
        vm.expectRevert();
        swapper.swap(a.key, true, -int256(1e18));
        vm.prank(bob);
        a.token.approve(address(swapper), type(uint256).max);
        vm.prank(bob);
        uint256 out = swapper.swapThrough(a.key, b.key, got / 2);
        assertGt(out, 0, "the netted route did not go through while paused");
        _assertChildBooks(a);
        _assertChildBooks(b);
        _pauseOndo(TSLAON, false);
        vm.clearMockedCalls();
        _sellChild(a, bob, a.token.balanceOf(bob));
        _assertChildBooks(a);
    }

    /// @dev USDC blocklists the PoolManager: every physical USDC transfer through it fails, for our child
    ///      and for any other USDC pool alike; after the unblock, everything resumes with exact books.
    function test_UsdcBlocklistedPoolManager() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        uint256 got = _buyChild(c, bob, 3_000e6);
        address blacklister = 0x0A06BE16275B95a7d2567fBdAE118b36C7DA78F9;
        vm.prank(blacklister);
        (bool ok,) = USDC.call(abi.encodeWithSignature("blacklist(address)", address(manager)));
        assertTrue(ok);
        vm.prank(bob);
        c.token.approve(address(swapper), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        swapper.swap(c.key, false, -int256(got / 2));
        vm.prank(blacklister);
        (ok,) = USDC.call(abi.encodeWithSignature("unBlacklist(address)", address(manager)));
        assertTrue(ok);
        _sellChild(c, bob, got / 2);
        _assertChildBooks(c);
    }

    /// @dev A blocklisted child team cannot be paid, but the pool keeps trading and the books keep the due.
    function test_BlocklistedTeamKeepsItsDue() public {
        (Child memory c,) = _launch(alice, USDC, 0);
        _buyChild(c, bob, 3_000e6);
        vm.prank(0x0A06BE16275B95a7d2567fBdAE118b36C7DA78F9);
        (bool ok,) = USDC.call(abi.encodeWithSignature("blacklist(address)", childTeam));
        assertTrue(ok);
        uint256 due = c.hook.teamAccrued();
        vm.expectRevert();
        c.hook.claimTeam();
        assertEq(c.hook.teamAccrued(), due, "the due was lost");
        _buyChild(c, bob, 1_000e6);
        _sellChild(c, bob, c.token.balanceOf(bob));
        _assertChildBooks(c);
    }

    /// @dev If USDT switches its transfer fee on, a payout from the PoolManager delivers less than
    ///      booked. The hook books the nominal amount: documented as an unsupported quote behaviour.
    function test_UsdtTransferFeeShortsTheRecipient() public {
        (Child memory c,) = _launch(alice, USDT, 0);
        _buyChild(c, bob, 3_000e6);
        vm.prank(0xC6CDE7C39eB2f0F0095F41570af89eFC2C1Ea828);
        (bool ok,) = USDT.call(abi.encodeWithSignature("setParams(uint256,uint256)", 10, 40));
        assertTrue(ok, "setParams failed");
        uint256 due = c.hook.teamAccrued();
        uint256 before = IERC20(USDT).balanceOf(childTeam);
        c.hook.claimTeam();
        uint256 received = IERC20(USDT).balanceOf(childTeam) - before;
        assertEq(c.hook.teamPaidCumulative(), due, "the hook books the nominal amount");
        assertLt(received, due, "the recipient was not shorted: the fee is off");
        emit log_named_uint("booked", due);
        emit log_named_uint("received", received);
    }

    /// @dev Ondo's admin grants itself the burn role and burns the PoolManager's TSLAon: payouts in TSLAon
    ///      then fail for every pool of that token, ours included, while the hook's books are unchanged.
    function test_OndoAdminBurnOnThePoolManager() public {
        (Child memory c,) = _launch(alice, TSLAON, 0);
        _buyChild(c, bob, 5e18);
        bytes32 burner = keccak256("BURNER_ROLE");
        (bool ok, bytes memory ret) = TSLAON.staticcall(abi.encodeWithSignature("getRoleMember(bytes32,uint256)", bytes32(0), 0));
        assertTrue(ok);
        address admin = abi.decode(ret, (address));
        vm.prank(admin);
        (ok,) = TSLAON.call(abi.encodeWithSignature("grantRole(bytes32,address)", burner, address(this)));
        assertTrue(ok, "grantRole failed");
        uint256 held = IERC20(TSLAON).balanceOf(address(manager));
        (ok,) = TSLAON.call(abi.encodeWithSignature("burn(address,uint256)", address(manager), held));
        assertTrue(ok, "burn failed");
        uint256 due = c.hook.teamAccrued();
        vm.expectRevert();
        c.hook.claimTeam();
        assertEq(c.hook.teamAccrued(), due);
        _assertChildBooks(c);
    }
}

/// @notice The switch on the real mainnet state. The fork takes the deployed CUBIT hook, registry, router,
///         Forge v1 and governance vault, deploys a Forge v2 on that vault, and plays the team's `setForge` and
///         `activate(8)` locally. CUBIT itself keeps trading, a v1 child launched just before the switch keeps
///         trading and feeding the vault, and a v2 child launches. Skipped unless FORK_BLOCK is set; it needs the state
///         while the registry named the Forge v1 with enabledFeatures 13: FORK_BLOCK from 26060363 to 26077038. The real Forge v1
///         froze the hash of CubitHook linked to the mainnet libraries, so link them for this run:
///           FORK_BLOCK=<block> forge test --match-contract QuoteLaunchpadMainnetStateTest --match-test Switch \
///             --libraries src/libraries/BandLib.sol:BandLib:0x307c5AF502f17ac9949def03A7F431AcB761866a \
///             --libraries src/libraries/WallLib.sol:WallLib:0x7A4CD811480a4550Ad558a7794655c1033d22EBD
contract QuoteLaunchpadMainnetStateTest is QuoteLaunchpadForkTest {
    CubitHook internal constant REAL_HOOK = CubitHook(payable(0xb64231a7a23efe2531C46B2d35A54BaC7Fed58Cc));
    CubitV2 internal constant REAL_REGISTRY = CubitV2(0x08c520172bdB8a61c6b93225ae00Eb90284BAd04);
    CubitRouter internal constant REAL_ROUTER = CubitRouter(payable(0x5a37794efb712A51Ef681B781dA5c6B44893e933));
    CubitForge internal constant REAL_FORGE_V1 = CubitForge(0x4B9F8E9C16899B7aF9dbBca3F062D8f46fe5dCbF);
    address internal constant REAL_GOVERNANCE = 0x441673C9f549Ce4a8D1Da222a361c44Ff7b424CA;
    address internal constant REAL_TEAM = 0xA252E2d2E9F337590D24Aa2dFc3eb891028AA505;

    function test_SwitchOnTheRealRegistry() public {
        // Rebind the suite's handles to the deployed release.
        hook = REAL_HOOK;
        registry = REAL_REGISTRY;
        governanceVault = CubitGovernanceVault(REAL_GOVERNANCE);
        assertEq(registry.forge(), address(REAL_FORGE_V1));
        assertEq(registry.enabledFeatures(), 13);

        // A v1 child, launched on the real Forge v1 before the switch.
        (address v1Token, address v1Hook) = _launchV1(REAL_FORGE_V1, alice);

        forgeV2 = new CubitForgeV2(REAL_HOOK, FEE, REAL_GOVERNANCE, _quotes(), _values());
        vm.startPrank(REAL_TEAM);
        registry.setForge(address(forgeV2));
        registry.activate(FORGE_BIT);
        vm.stopPrank();
        assertEq(registry.enabledFeatures(), 13, "the switch changed another feature");
        assertEq(registry.vault(), 0x45982c3aa120c2144Ea7b8cafB9f4D2BA7a9960a, "the staking vault moved");

        vm.deal(bob, FEE);
        vm.prank(bob);
        vm.expectRevert(bytes("Forge inactive"));
        REAL_FORGE_V1.launch{value: FEE}("Z", "Z", bob, bytes32(0), bytes32(0), type(CubitHook).creationCode);

        // CUBIT keeps trading through its own router.
        vm.deal(bob, 0.1 ether);
        vm.prank(bob);
        uint256 cubit = REAL_ROUTER.swapExactIn{value: 0.1 ether}(REAL_HOOK.poolKey(), true, 0.1 ether, 0, bob, type(uint256).max);
        assertGt(cubit, 0, "CUBIT stopped trading");

        // The v1 child keeps trading and feeding the governance vault.
        CubitHook ch = CubitHook(payable(v1Hook));
        Child memory c1 = Child(CubitForgeToken(v1Token), CubitQuoteHook(address(0)), ch.poolKey(), ETH);
        uint256 got = _buyChild(c1, bob, 1 ether);
        _sellChild(c1, bob, got / 10);
        _sellChild(c1, bob, CubitForgeToken(v1Token).balanceOf(bob));
        uint256 absorbed = ch.pendingAbsorbedTokens();
        assertGt(absorbed, 0);
        ch.deliverAbsorbed();
        assertEq(governanceVault.held(v1Token), absorbed, "the v1 child no longer feeds the real governance vault");

        // And a v2 child launches, its fee locked in the same vault.
        uint256 fees = governanceVault.held(address(0));
        (Child memory c2,) = _launch(alice, USDC, forgeV2.launchValue(USDC) / 100);
        assertEq(governanceVault.held(address(0)) - fees, FEE);
        _assertChildBooks(c2);
    }
}
