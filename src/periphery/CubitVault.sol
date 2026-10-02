// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CubitHook} from "../CubitHook.sol";
import {ICubitV2} from "../interfaces/ICubitV2.sol";

/// @notice Non-transferable CUBIT deposits. One reward stream, never any mint: CUBIT from a
///         pre-funded reserve, at a fixed daily rate. A staker earns DAILY_REWARD_BPS of their stake
///         per 24h, capped at exactly one period's worth — it does NOT keep accumulating past 24h, so
///         you must claim (roughly) daily or you forfeit the excess. Every reward CUBIT comes out of
///         `rewardReserve`, funded at launch and by the CUBIT of crossed walls; the reserve is finite,
///         so at a high rate it depletes and rewards then stop.
/// Deposits remain part of circulating supply. No owner, rescue, proxy or floor access.
contract CubitVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant LOCK_DURATION = 1 days;

    // CUBIT staking emission — a placeholder rate; the business logic holds if the number changes.
    uint256 public constant BPS = 10_000;
    uint256 public constant DAILY_REWARD_BPS = 300; // 3% of the stake per REWARD_PERIOD
    uint256 public constant REWARD_PERIOD = 1 days; // accrual window; unclaimed reward caps here

    CubitHook public immutable hook;
    IERC20 public immutable token;
    uint256 public totalStaked;

    // CUBIT reward reserve (e.g. the 20% launch allocation) and per-user accrual clock.
    uint256 public rewardReserve;
    uint256 public totalCubitPaid;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public unlockAt;
    mapping(address => uint256) public lastRewardAt; // start of the current CUBIT accrual window

    event Staked(address indexed user, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardReserveFunded(address indexed from, uint256 amount);
    event CubitRewardClaimed(address indexed user, uint256 amount);
    error Inactive();
    error InvalidAmount();
    error Locked();

    constructor(CubitHook hook_) {
        hook = hook_;
        token = IERC20(address(hook_.token()));
    }

    // ----------------------------------------------------------------- CUBIT rewards (reserve, daily)

    /// @notice CUBIT owed to `user` for the current window: DAILY_REWARD_BPS of the stake, prorated
    ///         over REWARD_PERIOD and **capped at one full period** (unclaimed reward never grows
    ///         past 3%). Never exceeds the remaining reserve.
    function pendingCubit(address user) public view returns (uint256 reward) {
        uint256 bal = balanceOf[user];
        if (bal == 0) return 0;
        uint256 elapsed = block.timestamp - lastRewardAt[user];
        if (elapsed > REWARD_PERIOD) elapsed = REWARD_PERIOD; // cap: claim daily or forfeit the excess
        reward = bal * DAILY_REWARD_BPS * elapsed / (BPS * REWARD_PERIOD);
        if (reward > rewardReserve) reward = rewardReserve; // never pay from principal or beyond the reserve
    }

    /// @dev Pay the pending CUBIT and restart the window. Called on claim and on any stake/withdraw
    ///      so a balance change never retroactively re-prices past accrual.
    function _settleCubit(address user) internal {
        uint256 reward = pendingCubit(user);
        lastRewardAt[user] = block.timestamp;
        if (reward != 0) {
            rewardReserve -= reward;
            totalCubitPaid += reward;
            token.safeTransfer(user, reward);
            emit CubitRewardClaimed(user, reward);
        }
    }

    function claimCubit() external nonReentrant {
        _settleCubit(msg.sender);
    }

    /// @notice Add CUBIT to the staking-reward reserve (the launch funds the 20% here). Permissionless:
    ///         anyone may top up the stakers' reward pool; it can never touch staked principal.
    function fundRewardReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        rewardReserve += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardReserveFunded(msg.sender, amount);
    }

    // ----------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        address registry = hook.v2();
        if (registry == address(0) || ICubitV2(registry).vault() != address(this) ||
            ICubitV2(registry).enabledFeatures() & 1 == 0) revert Inactive();
        if (amount == 0) revert InvalidAmount();
        _settleCubit(msg.sender); // pay CUBIT accrual on the old balance, restart the window
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        unlockAt[msg.sender] = block.timestamp + LOCK_DURATION;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, unlockAt[msg.sender]);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > balanceOf[msg.sender]) revert InvalidAmount();
        if (block.timestamp < unlockAt[msg.sender]) revert Locked();
        _settleCubit(msg.sender); // pay CUBIT accrual before the balance shrinks
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
