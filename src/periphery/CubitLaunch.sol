// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {CubitHook} from "../CubitHook.sol";
import {CubitToken} from "../CubitToken.sol";
import {CubitRouter} from "./CubitRouter.sol";
import {ICubitV2, ICubitVault} from "../interfaces/ICubitV2.sol";

/// @notice Atomic launch: the pool allocation into the band, the rest of the supply into the vault's reward
/// reserve, then an optional first fully taxed buy. The deployer approves the whole supply (21M) to this
/// contract before calling launch: the hook places MIN_POOL_SUPPLY (80%) in the band and the vault receives
/// the remaining 20% (4.2M) as the reserve its stakers are paid from.
/// No privileged buyer, team allocation, or launch-tax exception.
contract CubitLaunch {
    CubitHook public immutable hook;
    CubitToken public immutable token;

    constructor(CubitHook hook_, CubitRouter router_) {
        require(address(router_.hook()) == address(hook_), "wrong router");
        hook = hook_;
        token = hook_.token();
        require(address(router_) == ICubitV2(hook_.v2()).router(), "unregistered router");
    }

    /// @notice The launch follows the registry's current, validated router.
    function router() public view returns (CubitRouter) { return CubitRouter(payable(ICubitV2(hook.v2()).router())); }

    /// @notice Accepts only the router's refund during the optional first buy.
    /// @dev CubitRouter refunds its whole balance to its caller; a forced donation to the router
    ///      used to make a launch with an initial buy revert (RefundFailed). The change is
    ///      forwarded to the deployer before `launch` returns.
    receive() external payable {
        require(msg.sender == address(router()), "router refund only");
    }

    function launch(uint256 minCubitOut) external payable returns (uint256 bought) {
        require(msg.sender == token.deployer() && !hook.initialized(), "launch unavailable");
        address registry = hook.v2();
        require(registry != address(0), "V2 wiring missing");
        uint256 poolSupply = hook.MIN_POOL_SUPPLY();
        require(token.transferFrom(msg.sender, address(hook), poolSupply), "funding failed");
        hook.poolManager().initialize(hook.poolKey(), hook.INITIAL_SQRT_PRICE());
        // The other 20% never enters the pool: it seeds the reserve stakers are paid from, 3% of the stake per day.
        uint256 reserve = token.TOTAL_SUPPLY() - poolSupply;
        ICubitVault vault = ICubitVault(ICubitV2(registry).vault());
        require(token.transferFrom(msg.sender, address(this), reserve), "reserve funding failed");
        require(token.approve(address(vault), reserve), "reserve approval failed");
        vault.fundRewardReserve(reserve);
        if (msg.value != 0) {
            require(minCubitOut != 0, "minimum required");
            bought = router().swapExactIn{value: msg.value}(
                hook.poolKey(), true, msg.value, minCubitOut, msg.sender, block.timestamp
            );
        }
        uint256 change = address(this).balance;
        if (change != 0) {
            (bool ok,) = msg.sender.call{value: change}("");
            require(ok, "change refund failed");
        }
    }
}
