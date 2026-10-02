// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CubitGovernanceVault} from "../../src/periphery/CubitGovernanceVault.sol";

contract ChildToken is ERC20 {
    constructor() ERC20("Child", "CHILD") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Launchpad governance vault: every deposit waits its own 30 days, only the deployer claims.
contract CubitGovernanceVaultTest is Test {
    // Literal clock: under via_ir a local copy of block.timestamp is re-read after vm.warp.
    uint256 internal constant START = 1_000_000;

    CubitGovernanceVault internal vault;
    ChildToken internal token;
    address internal childHook = makeAddr("childHook");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vault = new CubitGovernanceVault(); // this test contract is the deployer
        token = new ChildToken();
        token.transfer(childHook, 10_000e18);
        vm.prank(childHook);
        token.approve(address(vault), type(uint256).max);
        vm.warp(START);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(childHook);
        vault.deposit(address(token), amount);
    }

    /// 10 tokens a day for 7 days: each batch waits its own month, the last one leaves on day 36.
    function test_eachDepositWaitsItsOwnMonth() public {
        for (uint256 day; day < 7; day++) {
            vm.warp(START + day * 1 days);
            _deposit(10e18);
        }
        assertEq(vault.held(address(token)), 70e18);

        vm.warp(START + 30 days - 1);
        vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
        vault.claim(address(token), type(uint256).max);

        vm.warp(START + 30 days);
        assertEq(vault.claim(address(token), type(uint256).max), 10e18);
        assertEq(vault.locked(address(token)), 60e18);

        vm.warp(START + 36 days - 1);
        assertEq(vault.claim(address(token), type(uint256).max), 50e18);

        vm.warp(START + 36 days);
        assertEq(vault.claim(address(token), type(uint256).max), 10e18);
        assertEq(vault.held(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 1_000_000e18 - 10_000e18 + 70e18);
    }

    function test_onlyTheDeployerClaims() public {
        _deposit(10e18);
        vm.warp(START + 30 days);
        vm.prank(stranger);
        vm.expectRevert(CubitGovernanceVault.NotDeployer.selector);
        vault.claim(address(token), type(uint256).max);
        vm.prank(childHook);
        vm.expectRevert(CubitGovernanceVault.NotDeployer.selector);
        vault.claim(address(token), type(uint256).max);
    }

    function test_claimsAreBoundedAndOldestFirst() public {
        for (uint256 i; i < 5; i++) {
            vm.warp(START + i * 1 hours);
            _deposit((i + 1) * 1e18);
        }
        vm.warp(START + 31 days);
        assertEq(vault.claim(address(token), 2), 3e18); // 1 + 2, the two oldest
        assertEq(vault.nextTranche(address(token)), 2);
        assertEq(vault.claim(address(token), type(uint256).max), 12e18); // 3 + 4 + 5
    }

    function test_plainTransferIsLockedOnceBooked() public {
        vm.prank(childHook);
        token.transfer(address(vault), 25e18);
        vm.warp(START + 2 days);
        vault.lockUntracked(address(token)); // anyone can book it; its month starts now
        (, uint256 unlockAt) = vault.tranche(address(token), 0);
        assertEq(unlockAt, START + 32 days);
        vm.expectRevert(CubitGovernanceVault.NothingToLock.selector);
        vault.lockUntracked(address(token));

        vm.warp(START + 32 days - 1);
        vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
        vault.claim(address(token), type(uint256).max);
        vm.warp(START + 32 days);
        assertEq(vault.claim(address(token), type(uint256).max), 25e18);
    }

    /// Random schedules: a claim never pays a tranche before its 30 days, and the books match the balance.
    function testFuzz_neverEarly(uint256 seed, uint256 claimAt) public {
        uint256 n = 1 + seed % 20;
        uint256[] memory arrivals = new uint256[](n);
        uint256 t = START;
        uint256 total;
        for (uint256 i; i < n; i++) {
            t += uint256(keccak256(abi.encode(seed, i))) % 3 days;
            vm.warp(t);
            _deposit(1e18 + i);
            arrivals[i] = t;
            total += 1e18 + i;
        }
        claimAt = bound(claimAt, t, t + 60 days);
        vm.warp(claimAt);
        uint256 expected;
        for (uint256 i; i < n; i++) {
            if (arrivals[i] + 30 days <= claimAt) expected += 1e18 + i;
        }
        if (expected == 0) {
            vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
            vault.claim(address(token), type(uint256).max);
        } else {
            assertEq(vault.claim(address(token), type(uint256).max), expected);
        }
        assertEq(vault.held(address(token)), total - expected);
        assertEq(token.balanceOf(address(vault)), total - expected);
    }

    // ------------------------------------------------------------------ ETH launch fees

    address internal constant ETH = address(0);

    /// The deployer receives claimed ETH.
    receive() external payable {}

    /// A launch fee in ETH waits its own 30 days like a token deposit, and only the deployer receives it.
    function test_ethFeeWaitsItsOwnMonth() public {
        address forge = makeAddr("forge");
        vm.deal(forge, 1 ether);
        vm.prank(forge);
        vault.depositEth{value: 0.01 ether}();
        vm.warp(START + 1 days);
        vm.prank(forge);
        vault.depositEth{value: 0.02 ether}();
        assertEq(vault.held(ETH), 0.03 ether);
        assertEq(address(vault).balance, 0.03 ether);

        vm.warp(START + 30 days - 1);
        vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
        vault.claim(ETH, type(uint256).max);

        vm.warp(START + 30 days);
        vm.prank(stranger);
        vm.expectRevert(CubitGovernanceVault.NotDeployer.selector);
        vault.claim(ETH, type(uint256).max);
        uint256 balance0 = address(this).balance;
        assertEq(vault.claim(ETH, type(uint256).max), 0.01 ether);
        assertEq(address(this).balance - balance0, 0.01 ether, "the deployer did not receive the ETH");
        assertEq(vault.locked(ETH), 0.02 ether);

        vm.warp(START + 31 days);
        assertEq(vault.claim(ETH, type(uint256).max), 0.02 ether);
        assertEq(vault.held(ETH), 0);
        assertEq(address(vault).balance, 0);
    }

    /// ETH that arrived without a deposit is booked by anyone, its month starting then; a deposit without value locks
    /// nothing.
    function test_untrackedEthIsLockedOnceBooked() public {
        vm.expectRevert(CubitGovernanceVault.NothingToLock.selector);
        vault.depositEth();
        vm.deal(address(vault), 0.5 ether); // forced ETH
        vm.warp(START + 2 days);
        vm.prank(stranger);
        vault.lockUntracked(ETH);
        (uint256 amount, uint256 unlockAt) = vault.tranche(ETH, 0);
        assertEq(amount, 0.5 ether);
        assertEq(unlockAt, START + 32 days);
        vm.expectRevert(CubitGovernanceVault.NothingToLock.selector);
        vault.lockUntracked(ETH);
        vm.warp(START + 32 days);
        assertEq(vault.claim(ETH, type(uint256).max), 0.5 ether);
    }

    /// ETH and token books never mix: each key claims only its own tranches.
    function test_ethAndTokenBooksAreSeparate() public {
        _deposit(10e18);
        vault.depositEth{value: 1 ether}();
        vm.warp(START + 30 days);
        assertEq(vault.claim(ETH, type(uint256).max), 1 ether);
        assertEq(vault.held(address(token)), 10e18, "an ETH claim touched the token book");
        assertEq(vault.claim(address(token), type(uint256).max), 10e18);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------ lock extension

    /// A year added: every tranche already inside and every later deposit waits 30 days plus that year; nothing leaves
    /// earlier, and the order stays oldest first.
    function test_extensionDelaysEveryTrancheAndEveryLaterDeposit() public {
        _deposit(10e18); // START
        vm.warp(START + 1 days);
        vault.depositEth{value: 1 ether}();
        vm.warp(START + 10 days);
        vault.extendLock(365 days);
        assertEq(vault.lockExtension(), 365 days);
        (, uint256 unlockAt) = vault.tranche(address(token), 0);
        assertEq(unlockAt, START + 30 days + 365 days, "the tranche date leaves the extension out");
        vm.warp(START + 40 days);
        _deposit(5e18); // arrives after the extension
        (, unlockAt) = vault.tranche(address(token), 1);
        assertEq(unlockAt, START + 40 days + 30 days + 365 days, "a later deposit skips the extension");

        vm.warp(START + 30 days + 365 days - 1);
        vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
        vault.claim(address(token), type(uint256).max);
        vm.warp(START + 30 days + 365 days);
        assertEq(vault.claim(address(token), type(uint256).max), 10e18);
        vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
        vault.claim(ETH, type(uint256).max);
        vm.warp(START + 31 days + 365 days);
        assertEq(vault.claim(ETH, type(uint256).max), 1 ether);
        vm.warp(START + 70 days + 365 days);
        assertEq(vault.claim(address(token), type(uint256).max), 5e18);
    }

    /// Only the deployer extends, as often as it wants; an empty extension is refused; locks follow the total.
    function test_onlyTheDeployerExtendsAndExtensionsAddUp() public {
        _deposit(10e18);
        vm.prank(stranger);
        vm.expectRevert(CubitGovernanceVault.NotDeployer.selector);
        vault.extendLock(1 days);
        vm.prank(childHook);
        vm.expectRevert(CubitGovernanceVault.NotDeployer.selector);
        vault.extendLock(1 days);
        vm.expectRevert(CubitGovernanceVault.NothingToExtend.selector);
        vault.extendLock(0);
        vault.extendLock(7 days);
        vault.extendLock(3 days);
        assertEq(vault.lockExtension(), 10 days);
        vm.warp(START + 40 days - 1);
        assertEq(vault.locked(address(token)), 10e18, "unlocked before 30 days plus the extensions");
        vm.warp(START + 40 days);
        assertEq(vault.locked(address(token)), 0);
        assertEq(vault.claim(address(token), 1), 10e18);
    }

    /// Random schedules with an extension in the middle: a claim never pays a tranche before its arrival plus 30 days
    /// plus the total extension, and the books match what is left.
    function testFuzz_neverEarlyWithAnExtension(uint256 seed, uint256 extension, uint256 claimAt) public {
        extension = bound(extension, 1, 3_650 days);
        uint256 n = 1 + seed % 10;
        uint256[] memory arrivals = new uint256[](n);
        uint256 t = START;
        uint256 total;
        for (uint256 i; i < n; i++) {
            t += uint256(keccak256(abi.encode(seed, i))) % 3 days;
            vm.warp(t);
            _deposit(1e18 + i);
            arrivals[i] = t;
            total += 1e18 + i;
            if (i == n / 2) vault.extendLock(uint64(extension));
        }
        claimAt = bound(claimAt, t, t + 30 days + extension + 10 days);
        vm.warp(claimAt);
        uint256 expected;
        for (uint256 i; i < n; i++) {
            if (arrivals[i] + 30 days + extension <= claimAt) expected += 1e18 + i;
        }
        if (expected == 0) {
            vm.expectRevert(CubitGovernanceVault.NothingToClaim.selector);
            vault.claim(address(token), type(uint256).max);
        } else {
            assertEq(vault.claim(address(token), type(uint256).max), expected);
        }
        assertEq(vault.held(address(token)), total - expected);
    }
}
