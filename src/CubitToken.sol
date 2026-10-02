// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CubitToken — CUBIT ERC-20
/// @notice Fixed supply of 21 000 000 (the GIZA / Bitcoin number), minted once to the
///         deployer at construction. There is no mint function in the runtime bytecode.
///         The only privileged function is `burn()`, restricted to the hook, which burns only
///         the rounding dust of its bootstrap deposit. Crossed walls do not burn: their CUBIT go
///         to the vault reserve, or to the launchpad governance vault for a Forge child.
/// @dev    `setHook()` is a one-shot wiring call by the deployer (DEPLOY.md step 4). Once
///         set, the deployer has no remaining power: the token has no owner.
contract CubitToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 21_000_000e18;

    /// @notice Deployer, only used to wire the hook once.
    address public immutable deployer;
    /// @notice The CubitHook — the only address allowed to burn.
    address public hook;
    /// @notice Cumulative tokens burned by the hook (monotone).
    uint256 public totalBurned;

    event HookSet(address indexed hook);
    event Burned(uint256 amount, uint256 totalBurned);

    error NotDeployer();
    error HookAlreadySet();
    error NotHook();
    error ZeroAddress();

    constructor() ERC20("CUBIT", "CUBIT") {
        deployer = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice One-shot: authorise the hook to burn. Reverts if already set.
    function setHook(address hook_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Burn tokens the hook holds. Hook only.
    function burn(uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        _burn(msg.sender, amount);
        totalBurned += amount;
        emit Burned(amount, totalBurned);
    }
}
