// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockQuote, MockNoReturnQuote} from "../../../script/mocks/TestQuotes.sol";
import {QuoteSwapper} from "../../../script/mocks/TestSwapper.sol";

/// @notice A governance vault that has code but refuses the launch fee: a launch must roll back entirely.
contract RefusingGovernanceVault {
    function depositEth() external payable {
        revert("refused");
    }

    function lockUntracked(address) external pure {}
}

