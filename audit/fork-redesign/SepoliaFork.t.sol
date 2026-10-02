// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {RedesignTaxesTest} from "../../test/redesign/RedesignTaxes.t.sol";
import {RedesignWallsTest} from "../../test/redesign/RedesignWalls.t.sol";
import {RedesignLaunchTest} from "../../test/redesign/RedesignLaunch.t.sol";
import {RedesignVaultTest} from "../../test/redesign/RedesignVault.t.sol";
import {RedesignEconomicsTest} from "../../test/redesign/RedesignEconomics.t.sol";
import {RedesignTransitionsTest} from "../../test/redesign/RedesignTransitions.t.sol";
import {RedesignInvariants} from "../../test/redesign/invariant/RedesignInvariants.t.sol";

/// @dev The canonical Uniswap v4 PoolManager on Sepolia.
address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

// The redesign suites, unchanged, against the canonical PoolManager's bytecode and
// state on a Sepolia fork pinned at FORK_BLOCK. RPC reads only: every transaction, balance and clock change stays in
// the local fork and live Sepolia is never changed. From the repository root, with SEPOLIA_RPC_URL exported from .env (never
// print it):
//   FOUNDRY_TEST=audit/fork-redesign FORK_BLOCK=<block> forge test --match-path audit/fork-redesign/SepoliaFork.t.sol

contract RedesignTaxesSepoliaForkTest is RedesignTaxesTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignWallsSepoliaForkTest is RedesignWallsTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignLaunchSepoliaForkTest is RedesignLaunchTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignVaultSepoliaForkTest is RedesignVaultTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignEconomicsSepoliaForkTest is RedesignEconomicsTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignTransitionsSepoliaForkTest is RedesignTransitionsTest {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}

contract RedesignInvariantsSepoliaFork is RedesignInvariants {
    function _poolManager() internal override returns (IPoolManager) {
        return _forkedPoolManager("SEPOLIA_RPC_URL", SEPOLIA_POOL_MANAGER);
    }
}
