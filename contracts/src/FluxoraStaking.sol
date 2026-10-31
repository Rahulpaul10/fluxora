// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

uint256 constant FLUXORA_MIN_REWARDS_DURATION = 7 days;
uint256 constant FLUXORA_MAX_REWARDS_DURATION = 365 days;

/// @title FLUXORA single-token staking rewards
/// @notice Stake FLUX to earn funded FLUX rewards; withdrawals and claims remain available while paused.
/// @dev Uses Unix seconds and 1e18 reward-per-token precision. Principal is tracked independently
///      from rewardReserve. Zero-stake intervals defer the remaining funded emissions until staking resumes.
///      Rounding dust may remain reserved and is not recoverable. Staking does not delegate votes on behalf of depositors.
/// @custom:upgrade-strategy Direct, non-upgradeable deployment (no proxy).
/// @dev Code changes require a replacement deployment and migration.
contract FluxoraStaking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant MIN_REWARDS_DURATION = FLUXORA_MIN_REWARDS_DURATION;
    uint256 public constant MAX_REWARDS_DURATION = FLUXORA_MAX_REWARDS_DURATION;
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    uint256 public rewardsDuration;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardReserve;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    error ZeroAddress();
    error InvalidToken(address token);
    error ZeroAmount();
    error InsufficientStake(uint256 requested, uint256 available);
    error InvalidDuration(uint256 duration);
    error RewardPeriodActive(uint256 periodFinish);
    error NoStakers();
    error ZeroRewardRate();
    error ProtectedToken();
    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error InsufficientRewardReserve(uint256 requestedReward, uint256 reserve);
    error InsufficientTokenBalance(uint256 tokenBalance, uint256 totalLiabilities);

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event RewardsDurationUpdated(uint256 duration);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    constructor(IERC20 token, address admin, address rewardsDistributor, address pauser, uint256 duration) {
        if (address(token) == address(0) || admin == address(0) || rewardsDistributor == address(0)
            || pauser == address(0)) revert ZeroAddress();
        if (address(token).code.length == 0) revert InvalidToken(address(token));
        _validateDuration(duration);
        stakingToken = token;
        rewardsDuration = duration;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, rewardsDistributor);
        _grantRole(PAUSER_ROLE, pauser);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 emission = (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        return rewardPerTokenStored + Math.mulDiv(emission, PRECISION, totalStaked);
    }

    function earned(address user) public view returns (uint256) {
        return rewards[user] + Math.mulDiv(balanceOf[user], rewardPerToken() - userRewardPerTokenPaid[user], PRECISION);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount);
    }

    /// @notice A consumed/front-run permit is tolerated; an adequate allowance is still required.
    function stakeWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external nonReentrant whenNotPaused
    {
        try IERC20Permit(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _stake(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _updateReward(msg.sender);
        _withdraw(msg.sender, amount);
    }

    function getReward() external nonReentrant {
        _updateReward(msg.sender);
        _payReward(msg.sender);
    }

    /// @notice Withdraw all principal and claim accrued rewards, including while paused.
    function exit() external nonReentrant {
        _updateReward(msg.sender);
        uint256 amount = balanceOf[msg.sender];
        // Settle both liabilities before either outgoing transfer.
        uint256 reward = _takeReward(msg.sender);
        if (amount != 0) {
            balanceOf[msg.sender] = 0;
            totalStaked -= amount;
        }
        if (amount != 0) {
            stakingToken.safeTransfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount);
        }
        if (reward != 0) {
            stakingToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        _checkSolvent();
    }

    /// @notice Pull new rewards from the distributor and restart the duration, merging unvested rewards.
    /// @dev Existing accrued liabilities are never reused to fund the new reward schedule.
    function notifyRewardAmount(uint256 reward) external nonReentrant onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        if (reward == 0) revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();
        _updateReward(address(0));
        uint256 leftover = block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRate : 0;
        uint256 rate = (reward + leftover) / rewardsDuration;
        if (rate == 0) revert ZeroRewardRate();
        rewardRate = rate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        rewardReserve += reward;
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), reward);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBalance;
        if (received != reward) revert UnexpectedTransferAmount(reward, received);
        _checkSolvent();
        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp < periodFinish) revert RewardPeriodActive(periodFinish);
        _validateDuration(duration);
        rewardsDuration = duration;
        emit RewardsDurationUpdated(duration);
    }

    /// @notice Recover unrelated ERC-20s only; FLUX principal and rewards can never be recovered.
    function recoverERC20(address token, address to, uint256 amount)
        external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(stakingToken)) revert ProtectedToken();
        if (token == address(0) || to == address(0) || to == address(this)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Recovered(token, to, amount);
    }

    function _updateReward(address user) private {
        uint256 accumulated = rewardPerToken();
        rewardPerTokenStored = accumulated;
        if (totalStaked == 0 && lastUpdateTime < periodFinish) {
            uint256 applicableTime = lastTimeRewardApplicable();
            periodFinish += applicableTime - lastUpdateTime;
            // Also shift past any gap after the old finish, preserving all remaining emissions.
            periodFinish += block.timestamp - applicableTime;
            lastUpdateTime = block.timestamp;
        } else {
            lastUpdateTime = lastTimeRewardApplicable();
        }
        if (user != address(0)) {
            rewards[user] += Math.mulDiv(balanceOf[user], accumulated - userRewardPerTokenPaid[user], PRECISION);
            userRewardPerTokenPaid[user] = accumulated;
        }
    }

    function _stake(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        _updateReward(user);
        totalStaked += amount;
        balanceOf[user] += amount;
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(user, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnexpectedTransferAmount(amount, received);
        _checkSolvent();
        emit Staked(user, amount);
    }

    function _withdraw(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[user]) revert InsufficientStake(amount, balanceOf[user]);
        balanceOf[user] -= amount;
        totalStaked -= amount;
        stakingToken.safeTransfer(user, amount);
        _checkSolvent();
        emit Withdrawn(user, amount);
    }

    function _takeReward(address user) private returns (uint256 reward) {
        reward = rewards[user];
        if (reward > rewardReserve) revert InsufficientRewardReserve(reward, rewardReserve);
        rewards[user] = 0;
        rewardReserve -= reward;
    }

    function _payReward(address user) private {
        uint256 reward = _takeReward(user);
        if (reward != 0) {
            stakingToken.safeTransfer(user, reward);
            emit RewardPaid(user, reward);
        }
        _checkSolvent();
    }

    function _checkSolvent() private view {
        uint256 tokenBalance = stakingToken.balanceOf(address(this));
        uint256 totalLiabilities = totalStaked + rewardReserve;
        if (tokenBalance < totalLiabilities) revert InsufficientTokenBalance(tokenBalance, totalLiabilities);
    }

    function _validateDuration(uint256 duration) private pure {
        if (duration < MIN_REWARDS_DURATION || duration > MAX_REWARDS_DURATION) revert InvalidDuration(duration);
    }
}
