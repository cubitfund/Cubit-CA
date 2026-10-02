// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

/// @title QuoteTaxes — the taxes a launcher chooses for a launchpad v2 child, and their bounds
/// @notice A launcher sets three rates at launch; they are then immutable in the child hook, like everything else
///         there. The launch fee paid to the governance vault is not one of them: it stays the Forge's, in ETH.
///           - `buyTeamBps`:  the tax on buys, all of it to the child's team (CUBIT: 3%);
///           - `sellTeamBps`: the team's share of the tax on sales (CUBIT: 3%);
///           - `sellWallBps`: the walls' share of the tax on sales (CUBIT: 12%).
///         The bounds protect buyers: a launcher cannot set a tax that traps sellers.
library QuoteTaxes {
    struct Taxes {
        uint16 buyTeamBps;
        uint16 sellTeamBps;
        uint16 sellWallBps;
    }

    uint256 internal constant MAX_BUY_TEAM_BPS = 500; // 5%
    uint256 internal constant MAX_SELL_TEAM_BPS = 500; // 5%
    uint256 internal constant MAX_SELL_WALL_BPS = 2_000; // 20%
    uint256 internal constant MAX_SELL_TAX_BPS = 2_500; // 25%, team and walls together

    /// @notice CUBIT's own rates: 3% on buys to the team, 15% on sales split 3% team and 12% walls.
    function cubit() internal pure returns (Taxes memory) {
        return Taxes({buyTeamBps: 300, sellTeamBps: 300, sellWallBps: 1_200});
    }

    function valid(Taxes memory t) internal pure returns (bool) {
        return t.buyTeamBps <= MAX_BUY_TEAM_BPS && t.sellTeamBps <= MAX_SELL_TEAM_BPS
            && t.sellWallBps <= MAX_SELL_WALL_BPS && uint256(t.sellTeamBps) + t.sellWallBps <= MAX_SELL_TAX_BPS;
    }
}
