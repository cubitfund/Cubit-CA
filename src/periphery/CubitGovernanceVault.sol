// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CubitGovernanceVault — the launchpad's governance vault
/// @notice Holds what the launchpad earns: the ETH launch fees and the tokens that Forge children's walls absorb.
///         Every deposit waits LOCK_DURATION from its own arrival, plus the extension the deployer added: 10 tokens
///         received each day for 7 days unlock one batch a day, from day 30 to day 36, or from day 395 to day 401 once
///         a year was added. Only the deployer can claim, and only the batches whose date has passed. Only the deployer
///         can extend, at any time and as often as it wants, for every token and ETH; a lock never shortens. Its
///         holdings are the NAV reference of the launchpad token.
/// @dev    No owner transfer, no admin, no early exit. Deposits are permissionless: they can only add locked value.
///         ETH is booked under the key `ETH` (address zero). The extension applies to every tranche, present and
///         future, so unlock dates keep the arrival order and a claim walks them oldest first, in bounded batches.
contract CubitGovernanceVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant LOCK_DURATION = 30 days;
    /// @notice The key ETH is booked under.
    address public constant ETH = address(0);

    struct Tranche {
        uint256 amount;
        uint256 unlockAt; // arrival + LOCK_DURATION; the extension is added on every read
    }

    address public immutable deployer;
    /// @notice Seconds the deployer added to every lock, present and future. It only grows.
    uint64 public lockExtension;
    /// @notice Tokens (or ETH, under `ETH`) received and not yet claimed, locked or unlocked.
    mapping(address token => uint256) public held;
    /// @notice Index of the oldest unclaimed tranche, per token.
    mapping(address token => uint256) public nextTranche;
    mapping(address token => Tranche[]) internal _tranches;

    event Deposited(address indexed token, address indexed from, uint256 amount, uint256 unlockAt);
    event Claimed(address indexed token, uint256 amount, uint256 tranches);
    /// @notice Every lock, present and future, now waits `lockExtension` seconds more than LOCK_DURATION.
    event LockExtended(uint256 added, uint256 lockExtension);

    error NotDeployer();
    error NothingToLock();
    error NothingToClaim();
    error NothingToExtend();
    error EthTransferFailed();

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Pull `amount` of `token` from the caller and lock it.
    function deposit(address token, uint256 amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _lockNew(token, msg.sender);
    }

    /// @notice Lock the ETH sent with the call, such as a launch fee.
    function depositEth() external payable nonReentrant {
        _lockNew(ETH, msg.sender);
    }

    /// @notice Lock tokens, or ETH under `ETH`, that arrived without a deposit. Their lock starts when they are booked.
    function lockUntracked(address token) external nonReentrant {
        _lockNew(token, msg.sender);
    }

    /// @notice Add `extra` seconds to the lock of every tranche, present and future, of every token and ETH. Only the
    ///         deployer, at any time, as often as it wants; nothing can shorten a lock.
    function extendLock(uint64 extra) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (extra == 0) revert NothingToExtend();
        lockExtension += extra;
        emit LockExtended(extra, lockExtension);
    }

    /// @notice Send the unlocked tranches of `token` (ETH under `ETH`) to the deployer, oldest first, at most
    ///         `maxTranches`.
    function claim(address token, uint256 maxTranches) external nonReentrant returns (uint256 amount) {
        if (msg.sender != deployer) revert NotDeployer();
        Tranche[] storage tranches = _tranches[token];
        uint256 extension = lockExtension;
        uint256 i = nextTranche[token];
        uint256 count;
        while (i < tranches.length && count < maxTranches && tranches[i].unlockAt + extension <= block.timestamp) {
            amount += tranches[i].amount;
            delete tranches[i];
            i++;
            count++;
        }
        if (amount == 0) revert NothingToClaim();
        nextTranche[token] = i;
        held[token] -= amount;
        if (token == ETH) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Claimed(token, amount, count);
    }

    /// @notice What `claim` would send right now, and how many tranches that covers.
    function claimable(address token) public view returns (uint256 amount, uint256 tranches) {
        Tranche[] storage list = _tranches[token];
        uint256 extension = lockExtension;
        for (uint256 i = nextTranche[token]; i < list.length && list[i].unlockAt + extension <= block.timestamp; i++) {
            amount += list[i].amount;
            tranches++;
        }
    }

    /// @notice Tokens (or ETH) still waiting for their unlock date.
    function locked(address token) external view returns (uint256) {
        (uint256 unlocked,) = claimable(token);
        return held[token] - unlocked;
    }

    function trancheCount(address token) external view returns (uint256) {
        return _tranches[token].length;
    }

    /// @notice A tranche and its unlock date, extension included.
    function tranche(address token, uint256 index) external view returns (uint256 amount, uint256 unlockAt) {
        Tranche storage t = _tranches[token][index];
        return (t.amount, t.unlockAt + lockExtension);
    }

    /// @dev Everything the vault holds beyond its books becomes one new tranche. The event carries the unlock date at
    ///      arrival, extension included; a later `LockExtended` pushes it further.
    function _lockNew(address token, address from) internal {
        uint256 balance = token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (balance <= held[token]) revert NothingToLock();
        uint256 amount = balance - held[token];
        uint256 unlockAt = block.timestamp + LOCK_DURATION;
        _tranches[token].push(Tranche(amount, unlockAt));
        held[token] += amount;
        emit Deposited(token, from, amount, unlockAt + lockExtension);
    }
}
