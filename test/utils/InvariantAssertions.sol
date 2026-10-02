// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

/// @dev Shared by Foundry and Medusa. Successful checks make no cheatcode calls. On failure,
///      console logging preserves the diagnostic in the trace, then Solidity emits Panic(0x01).
///      A forge-std assertion cheatcode or a string revert is not a Medusa assertion failure.
function assertInvariant(bool condition, string memory message) pure {
    if (!condition) {
        console2.log(message);
        assert(condition);
    }
}
