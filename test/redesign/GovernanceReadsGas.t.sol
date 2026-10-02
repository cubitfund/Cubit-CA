// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {CubitGovernanceVault} from "../../src/periphery/CubitGovernanceVault.sol";

// The installed Forge supports cool; the vendored forge-std predates its declaration.
interface GovernanceColdVm {
    function cool(address target) external;
}

/// @dev Real, unchanged vault bytecode. Only the deposit book is seeded in storage, outside the measured calls.
/// Run alone with -j 1 --isolate for cold measurements; no fork, script or network is involved.
contract GovernanceReadsGasTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant BUDGET = 16_777_216;
    uint256 internal constant UNLOCK = 3_592_000;
    CubitGovernanceVault internal vault;
    uint256 internal countSlot;
    uint256 internal heldSlot;

    function setUp() public {
        vault = new CubitGovernanceVault();
        vault.extendLock(100);
        countSlot = stdstore.target(address(vault)).sig("trancheCount(address)").with_key(address(0)).find();
        heldSlot = stdstore.target(address(vault)).sig("held(address)").with_key(address(0)).find();
        uint256 data = uint256(keccak256(abi.encode(countSlot)));
        for (uint256 i; i < 20_000; i++) {
            vm.store(address(vault), bytes32(data + 2 * i), bytes32(uint256(1)));
            vm.store(address(vault), bytes32(data + 2 * i + 1), bytes32(UNLOCK));
        }
        vm.warp(UNLOCK + 100); // every row has matured, including the lock extension
    }

    function test_gas_fixedGovernanceGettersAt0_4000_20000Tranches() public {
        uint256[3] memory counts = [uint256(0), 4_000, 20_000];
        bytes[] memory getters = new bytes[](6);
        getters[0] = abi.encodeWithSignature("deployer()");
        getters[1] = abi.encodeWithSignature("LOCK_DURATION()");
        getters[2] = abi.encodeWithSignature("lockExtension()");
        getters[3] = abi.encodeWithSignature("held(address)", address(0));
        getters[4] = abi.encodeCall(CubitGovernanceVault.trancheCount, (address(0)));
        getters[5] = abi.encodeWithSignature("nextTranche(address)", address(0));
        string[6] memory names = ["deployer", "LOCK_DURATION", "lockExtension", "held", "trancheCount", "nextTranche"];
        uint256[6] memory baseline;
        uint256 trancheGas;
        for (uint256 n; n < counts.length; n++) {
            uint256 count = counts[n];
            vm.store(address(vault), bytes32(countSlot), bytes32(count));
            vm.store(address(vault), bytes32(heldSlot), bytes32(count));
            vm.deal(address(vault), count);
            assertEq(vault.trancheCount(address(0)), count);
            assertEq(vault.held(address(0)), count);
            assertEq(vault.nextTranche(address(0)), 0);
            console2.log("tranches", count);
            for (uint256 i; i < getters.length; i++) {
                (uint256 gasUsed, bytes memory result) = _measure(getters[i]);
                assertEq(result.length, 32);
                console2.log(names[i], gasUsed);
                if (n == 0) baseline[i] = gasUsed;
                else assertEq(gasUsed, baseline[i], "fixed getter grew with tranche count");
            }
            if (count != 0) {
                (uint256 gasUsed, bytes memory result) = _measure(abi.encodeCall(CubitGovernanceVault.tranche, (address(0), count - 1)));
                (uint256 amount, uint256 unlockAt) = abi.decode(result, (uint256, uint256));
                assertEq(amount, 1);
                assertEq(unlockAt, UNLOCK + 100);
                console2.log("tranche(last)", gasUsed);
                if (trancheGas == 0) trancheGas = gasUsed;
                else assertEq(gasUsed, trancheGas, "individual tranche read grew with count/index");

                // Negative controls: the original getters still exceed the RPC budget. The app must avoid them.
                GovernanceColdVm(address(vm)).cool(address(vault));
                (bool claimableOk,) = address(vault).staticcall{gas: BUDGET}(abi.encodeCall(CubitGovernanceVault.claimable, (address(0))));
                assertFalse(claimableOk, "unbounded claimable unexpectedly fits the budget");
                GovernanceColdVm(address(vm)).cool(address(vault));
                (bool lockedOk,) = address(vault).staticcall{gas: BUDGET}(abi.encodeCall(CubitGovernanceVault.locked, (address(0))));
                assertFalse(lockedOk, "unbounded locked unexpectedly fits the budget");
            }
        }
    }

    function _measure(bytes memory data) internal returns (uint256 gasUsed, bytes memory result) {
        GovernanceColdVm(address(vm)).cool(address(vault));
        bool ok;
        (ok, result) = address(vault).staticcall{gas: BUDGET}(data);
        gasUsed = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok, "fixed getter exceeded the read budget");
        assertLt(gasUsed, 10_000);
    }
}
