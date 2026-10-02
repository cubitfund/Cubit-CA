// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CubitLens} from "../../src/CubitLens.sol";
import {ICubitLens} from "../../src/interfaces/ICubitLens.sol";

/// @dev Test-side consumer of the paginated API. Production supply derivation lives in the app's src/chain/lens.ts.
library LensReads {
    function wallAmounts(CubitLens lens) internal view returns (uint256 eth, uint256 tokens) {
        uint256 total = lens.activeWallCount();
        uint256 next;
        while (next < total) {
            (uint256 a0, uint256 a1, uint256 end, uint256 count) = lens.wallAmountsPage(next, 1_000);
            require(count == total && end > next, "invalid wall page");
            eth += a0;
            tokens += a1;
            next = end;
        }
    }

    function wallEth(CubitLens lens) internal view returns (uint256 eth) {
        (eth,) = wallAmounts(lens);
    }

    function wallTokens(CubitLens lens) internal view returns (uint256 tokens) {
        (, tokens) = wallAmounts(lens);
        tokens += lens.hook().pendingAbsorbedTokens();
    }

    function circulatingSupply(CubitLens lens) internal view returns (uint256) {
        ICubitLens.Snapshot memory s = lens.snapshot();
        uint256 excluded = wallTokens(lens) + s.rewardReserve;
        return s.totalSupply > excluded ? s.totalSupply - excluded : 0;
    }

    function heldSupply(CubitLens lens) internal view returns (uint256) {
        uint256 circulating = circulatingSupply(lens);
        uint256 band = lens.bandTokens();
        return circulating > band ? circulating - band : 0;
    }
}
