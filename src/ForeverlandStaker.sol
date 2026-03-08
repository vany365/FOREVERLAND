// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IForeverland.sol";

/// @title ForeverlandStaker
/// @notice Stake yDUST to earn USDC revenue from Neverland's protocol fees.
///
/// @dev Reward mechanics:
///   - Standard Synthetix-style rewardPerToken accumulation
///   - 7-day epoch ramp: deposits made in the current epoch earn at 0.5x weight
///     until the next epoch boundary passes, then permanently 1x
///   - Whitelisted addresses (the Vault) earn 1x immediately with no ramp
///   - No lock — users can unstake at any time
///   - USDC rewards are claimable at any time and never expire
///
/// @dev Epoch definition:
///   An epoch is a 7-day window starting from `epochStart`. The epoch number
///   for any timestamp = (timestamp - epochStart) / EPOCH_DURATION.
///   The Locker calls notifyRewardAmount once per week after harvesting.
contract ForeverlandStaker {
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant EPOCH_DURATION   = 7 days;
    uint256 public constant PRECISION        = 1e18;
    uint256 public constant HALF_WEIGHT_BPS  = 5_000;  // 0.5x = 5000/10000
    uint256 public constant FULL_WEIGHT_BPS  = 10_000; // 1.0x = 10000/10000
    uint256 public constant WEIGHT_DENOM     = 10_000;

    // =========================================================================
    // Immutables
    // =========================================================================

    IERC20  public immutable yDust;   // yDUST staking token
    IERC20  public immutable usdc;    // USDC reward token
    address public immutable locker;  // ForeverlandLocker — only source of rewards
    uint256 public immutable epochStart; // Timestamp of contract deployment

    // =========================================================================
    // State
    // =========================================================================

    address public owner;
    address public pendingOwner;

    /// @notice Accumulated USDC reward per weighted token unit (scaled by PRECISION)
    uint256 public rewardPerTokenStored;

    /// @notice Total weighted yDUST across all stakers
    uint256 public totalWeightedSupply;

    /// @notice Whitelisted addresses earn immediate 1x (the Vault)
    mapping(address => bool) public whitelisted;

    // =========================================================================
    // Per-user State
    // =========================================================================

    /// @notice A single stake position (users can have multiple)
    struct StakePosition {
        uint128 amount;           // yDUST staked in this position
        uint64  depositEpoch;     // Epoch number when this position was created
        uint128 rewardDebt;       // rewardPerToken snapshot at last claim
    }

    /// @notice All stake positions per user (multiple deposits tracked separately)
    mapping(address => StakePosition[]) public positions;

    /// @notice Pending USDC rewards not yet claimed
    mapping(address => uint256) public pendingRewards;

    // =========================================================================
    // Events
    // =========================================================================

    event Staked(address indexed user, uint256 positionIndex, uint256 amount, uint256 epoch);
    event Unstaked(address indexed user, uint256 positionIndex, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 epoch);
    event Whitelisted(address indexed addr, bool status);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotOwner();
    error NotLocker();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPosition();
    error InsufficientStake();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _owner,
        address _yDust,
        address _usdc,
        address _locker
    ) {
        if (_owner  == address(0)) revert ZeroAddress();
        if (_yDust  == address(0)) revert ZeroAddress();
        if (_usdc   == address(0)) revert ZeroAddress();
        if (_locker == address(0)) revert ZeroAddress();

        owner      = _owner;
        yDust      = IERC20(_yDust);
        usdc       = IERC20(_usdc);
        locker     = _locker;
        epochStart = block.timestamp;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyLocker() {
        if (msg.sender != locker) revert NotLocker();
        _;
    }

    // =========================================================================
    // Epoch Logic
    // =========================================================================

    /// @notice Returns the current epoch number (0-indexed)
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - epochStart) / EPOCH_DURATION;
    }

    /// @notice Returns the weight in basis points for a given stake position
    /// @dev Whitelisted addresses always return FULL_WEIGHT_BPS
    function weightOf(address user, uint256 positionIndex) public view returns (uint256) {
        if (whitelisted[user]) return FULL_WEIGHT_BPS;
        StakePosition storage pos = positions[user][positionIndex];
        if (currentEpoch() > pos.depositEpoch) {
            return FULL_WEIGHT_BPS;  // Past the deposit epoch — full weight
        }
        return HALF_WEIGHT_BPS;  // Still in deposit epoch — half weight
    }

    /// @notice Returns effective weighted balance for a position
    function weightedBalance(address user, uint256 positionIndex) public view returns (uint256) {
        StakePosition storage pos = positions[user][positionIndex];
        return (uint256(pos.amount) * weightOf(user, positionIndex)) / WEIGHT_DENOM;
    }

    // =========================================================================
    // Stake
    // =========================================================================

    /// @notice Stake yDUST to start earning USDC rewards.
    /// @dev Creates a new position. Each deposit is tracked independently
    ///      so that weight ramp-up is per-deposit, not per-user.
    /// @param amount Amount of yDUST to stake
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Settle any pending rewards across all existing positions before
        // the weighted supply changes
        _settleUser(msg.sender);

        // Pull yDUST from caller
        yDust.transferFrom(msg.sender, address(this), amount);

        // Determine effective weight for this new position
        uint256 epoch = currentEpoch();
        uint256 w = whitelisted[msg.sender] ? FULL_WEIGHT_BPS : HALF_WEIGHT_BPS;
        uint256 weighted = (amount * w) / WEIGHT_DENOM;

        // Add new position
        positions[msg.sender].push(StakePosition({
            amount:      uint128(amount),
            depositEpoch: uint64(epoch),
            rewardDebt:  uint128(rewardPerTokenStored)
        }));

        totalWeightedSupply += weighted;

        emit Staked(msg.sender, positions[msg.sender].length - 1, amount, epoch);
    }

    // =========================================================================
    // Unstake
    // =========================================================================

    /// @notice Unstake yDUST from a specific position.
    /// @dev Automatically claims any pending USDC rewards for that position.
    /// @param positionIndex Index of the position to unstake from
    /// @param amount Amount of yDUST to unstake (can be partial)
    function unstake(uint256 positionIndex, uint256 amount) external {
        StakePosition[] storage userPositions = positions[msg.sender];
        if (positionIndex >= userPositions.length) revert InvalidPosition();

        StakePosition storage pos = userPositions[positionIndex];
        if (amount == 0 || amount > uint256(pos.amount)) revert InsufficientStake();

        // Settle rewards before changing balances
        _settleUser(msg.sender);

        // Update weighted supply
        uint256 w = weightOf(msg.sender, positionIndex);
        uint256 weightedRemoved = (amount * w) / WEIGHT_DENOM;
        totalWeightedSupply -= weightedRemoved;

        // Update position
        unchecked { pos.amount -= uint128(amount); }

        // If position is now empty, remove it by swapping with last
        if (pos.amount == 0) {
            userPositions[positionIndex] = userPositions[userPositions.length - 1];
            userPositions.pop();
        }

        // Return yDUST
        yDust.transfer(msg.sender, amount);

        emit Unstaked(msg.sender, positionIndex, amount);
    }

    /// @notice Unstake ALL yDUST across all positions
    function unstakeAll() external {
        _settleUser(msg.sender);

        StakePosition[] storage userPositions = positions[msg.sender];
        uint256 len = userPositions.length;
        if (len == 0) return;

        uint256 totalAmount;
        for (uint256 i; i < len; ) {
            StakePosition storage pos = userPositions[i];
            uint256 w = weightOf(msg.sender, i);
            uint256 weighted = (uint256(pos.amount) * w) / WEIGHT_DENOM;
            totalWeightedSupply -= weighted;
            totalAmount += uint256(pos.amount);
            unchecked { ++i; }
        }

        // Clear all positions
        delete positions[msg.sender];

        yDust.transfer(msg.sender, totalAmount);
        emit Unstaked(msg.sender, type(uint256).max, totalAmount);
    }

    // =========================================================================
    // Claim Rewards
    // =========================================================================

    /// @notice Claim all pending USDC rewards
    function claim() external {
        _settleUser(msg.sender);
        uint256 pending = pendingRewards[msg.sender];
        if (pending == 0) return;
        pendingRewards[msg.sender] = 0;
        usdc.transfer(msg.sender, pending);
        emit RewardClaimed(msg.sender, pending);
    }

    /// @notice Preview claimable USDC for a user (includes unsettled)
    function claimable(address user) external view returns (uint256) {
        uint256 pending = pendingRewards[user];
        StakePosition[] storage userPositions = positions[user];
        uint256 len = userPositions.length;
        for (uint256 i; i < len; ) {
            StakePosition storage pos = userPositions[i];
            uint256 w = whitelisted[user] ? FULL_WEIGHT_BPS : (
                currentEpoch() > uint256(pos.depositEpoch) ? FULL_WEIGHT_BPS : HALF_WEIGHT_BPS
            );
            uint256 weighted = (uint256(pos.amount) * w) / WEIGHT_DENOM;
            uint256 earned = (weighted * (rewardPerTokenStored - uint256(pos.rewardDebt))) / PRECISION;
            pending += earned;
            unchecked { ++i; }
        }
        return pending;
    }

    // =========================================================================
    // Notify Reward (Locker only)
    // =========================================================================

    /// @notice Called by the Locker after harvesting USDC from Neverland.
    /// @dev Updates rewardPerTokenStored. USDC must be transferred before calling.
    /// @param amount USDC amount being distributed this epoch
    function notifyRewardAmount(uint256 amount) external onlyLocker {
        if (amount == 0) return;

        // Update epoch weights before distributing
        // (epoch transitions are lazy — settled per-user on interaction)
        if (totalWeightedSupply > 0) {
            rewardPerTokenStored += (amount * PRECISION) / totalWeightedSupply;
        }
        // If no stakers, USDC sits in the contract and is distributed when
        // the next staker arrives (not ideal but acceptable for v1)

        emit RewardNotified(amount, currentEpoch());
    }

    // =========================================================================
    // Internal: Settle Rewards
    // =========================================================================

    /// @notice Settle earned rewards and update epoch weights for a user.
    /// @dev Must be called before any stake/unstake/claim operation.
    function _settleUser(address user) internal {
        StakePosition[] storage userPositions = positions[user];
        uint256 len = userPositions.length;
        uint256 epoch = currentEpoch();

        for (uint256 i; i < len; ) {
            StakePosition storage pos = userPositions[i];

            // Calculate current effective weight
            uint256 w = whitelisted[user] ? FULL_WEIGHT_BPS : (
                epoch > uint256(pos.depositEpoch) ? FULL_WEIGHT_BPS : HALF_WEIGHT_BPS
            );
            uint256 weighted = (uint256(pos.amount) * w) / WEIGHT_DENOM;

            // Check if this position transitioned from 0.5x to 1x since last settle
            // If so, we need to update totalWeightedSupply
            bool wasHalf = !whitelisted[user] && (uint256(pos.depositEpoch) == epoch - 1)
                && uint256(pos.rewardDebt) == rewardPerTokenStored; // simplification: check via epoch

            if (!whitelisted[user] && epoch > uint256(pos.depositEpoch)) {
                // Position graduated to 1x — check if totalWeightedSupply needs updating
                // We track this by seeing if the stored weight was 0.5x
                // Simple approach: recalculate and correct
                uint256 oldWeighted = (uint256(pos.amount) * HALF_WEIGHT_BPS) / WEIGHT_DENOM;
                uint256 newWeighted = (uint256(pos.amount) * FULL_WEIGHT_BPS) / WEIGHT_DENOM;
                // Only upgrade once — we use rewardDebt to detect if already upgraded
                // A position that was created at 0.5x and hasn't been touched will have
                // its depositEpoch < currentEpoch. We upgrade it here.
                if (oldWeighted != newWeighted && pos.depositEpoch + 1 == uint64(epoch)) {
                    // Just crossed the epoch boundary for this position
                    totalWeightedSupply = totalWeightedSupply - oldWeighted + newWeighted;
                }
            }

            // Accumulate earned rewards
            uint256 earned = (weighted * (rewardPerTokenStored - uint256(pos.rewardDebt))) / PRECISION;
            pendingRewards[user] += earned;
            pos.rewardDebt = uint128(rewardPerTokenStored);

            unchecked { ++i; }
        }
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Total yDUST staked by a user across all positions
    function totalStaked(address user) external view returns (uint256 total) {
        StakePosition[] storage userPositions = positions[user];
        uint256 len = userPositions.length;
        for (uint256 i; i < len; ) {
            total += uint256(userPositions[i].amount);
            unchecked { ++i; }
        }
    }

    /// @notice Number of stake positions for a user
    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    /// @notice Get a specific position
    function getPosition(address user, uint256 index)
        external view returns (uint256 amount, uint256 depositEpoch, uint256 rewardDebt)
    {
        StakePosition storage pos = positions[user][index];
        return (uint256(pos.amount), uint256(pos.depositEpoch), uint256(pos.rewardDebt));
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setWhitelisted(address addr, bool status) external onlyOwner {
        whitelisted[addr] = status;
        emit Whitelisted(addr, status);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
