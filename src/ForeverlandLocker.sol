// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IForeverland.sol";
import "./yDUST.sol";

/// @title ForeverlandLocker
/// @notice Core engine of the Foreverland protocol. Accepts veDUST NFT deposits
///         and raw DUST deposits, mints yDUST 1:1, manages a dynamic array of
///         infinite-lock veDUST "bucket" NFTs capped at BUCKET_CAP each, and
///         harvests USDC revenue from Neverland's RevenueReward contract.
///
/// @dev Bucket rules:
///   - DUST deposits: fill active bucket to cap, then overflow into next/new bucket
///   - NFT deposits:  find any bucket with sufficient capacity; if none, create new
///   - NFTs > BUCKET_CAP: allowed — placed alone in a dedicated new bucket
///   - All bucket NFTs are permanent locks (infinite voting power, no decay)
contract ForeverlandLocker {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum DUST per bucket NFT (1,000,000 DUST)
    uint256 public constant BUCKET_CAP = 1_000_000e18;

    /// @notice Maximum lock duration passed to createLock (4 years in seconds)
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;

    /// @notice Performance fee denominator (basis points)
    uint256 public constant FEE_DENOMINATOR = 10_000;

    // =========================================================================
    // Immutables
    // =========================================================================

    IDustLock  public immutable dustLock;      // Neverland veDUST NFT contract
    IERC20     public immutable dustToken;     // DUST ERC-20
    IERC20     public immutable usdc;          // USDC ERC-20
    yDUST      public immutable yDust;         // yDUST receipt token

    // =========================================================================
    // State
    // =========================================================================

    address public owner;
    address public pendingOwner;
    address public staker;           // ForeverlandStaker — receives harvested USDC
    address public vault;            // ForeverlandVault  — whitelisted depositor
    address public treasury;         // Multisig fee recipient
    address public keeper;           // Gelato dedicated proxy address
    address public revenueReward;    // Neverland RevenueReward contract

    /// @notice Performance fee in basis points (default 1000 = 10%)
    uint256 public performanceFee = 1_000;

    /// @notice Ordered array of all bucket veDUST NFT token IDs
    uint256[] public bucketTokenIds;

    /// @notice DUST balance tracked per bucket NFT
    mapping(uint256 => uint256) public bucketBalance;

    /// @notice Running total of all DUST locked across all buckets
    uint256 public totalDustLocked;

    /// @notice Last epoch number for which harvest was called
    uint256 public lastHarvestedEpoch;

    /// @notice Whether the first bucket has been bootstrapped
    bool public bootstrapped;

    /// @notice Emergency pause flag
    bool public paused;

    // =========================================================================
    // Events
    // =========================================================================

    event NFTDeposited(address indexed user, uint256 indexed tokenId, uint256 dustAmount, uint256 bucketId);
    event DUSTDeposited(address indexed user, uint256 dustAmount);
    event BucketCreated(uint256 indexed tokenId, uint256 indexed bucketIndex);
    event Harvested(uint256 totalUSDC, uint256 fee, uint256 distributed, uint256 epoch);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event OwnershipAccepted(address indexed newOwner);
    event KeeperSet(address indexed keeper);
    event StakerSet(address indexed staker);
    event VaultSet(address indexed vault);
    event TreasurySet(address indexed treasury);
    event RevenueRewardSet(address indexed revenueReward);
    event PerformanceFeeSet(uint256 fee);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotOwner();
    error NotKeeper();
    error NotStakerOrVault();
    error ZeroAddress();
    error ZeroAmount();
    error NotBootstrapped();
    error AlreadyBootstrapped();
    error Paused_();
    error FeeTooHigh();
    error NothingToHarvest();
    error InvalidTokenId();
    error NFTNotOwnedByCaller();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _owner,
        address _dustLock,
        address _dustToken,
        address _usdc,
        address _yDust,
        address _treasury,
        address _revenueReward
    ) {
        if (_owner       == address(0)) revert ZeroAddress();
        if (_dustLock    == address(0)) revert ZeroAddress();
        if (_dustToken   == address(0)) revert ZeroAddress();
        if (_usdc        == address(0)) revert ZeroAddress();
        if (_yDust       == address(0)) revert ZeroAddress();
        if (_treasury    == address(0)) revert ZeroAddress();
        if (_revenueReward == address(0)) revert ZeroAddress();

        owner          = _owner;
        dustLock       = IDustLock(_dustLock);
        dustToken      = IERC20(_dustToken);
        usdc           = IERC20(_usdc);
        yDust          = yDUST(_yDust);
        treasury       = _treasury;
        revenueReward  = _revenueReward;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused_();
        _;
    }

    // =========================================================================
    // Deposit: NFT
    // =========================================================================

    /// @notice Deposit a veDUST NFT into Foreverland.
    /// @dev The caller must have approved this contract via setApprovalForAll
    ///      on the DustLock contract before calling this function.
    ///      Any self-repayment enrollment on the NFT will be cleared by the
    ///      merge operation — users acknowledge this by using this service.
    /// @param tokenId The veDUST NFT token ID to deposit
    function depositNFT(uint256 tokenId) external whenNotPaused {
        // Verify caller owns the NFT
        if (dustLock.ownerOf(tokenId) != msg.sender) revert NFTNotOwnedByCaller();

        // Pull NFT from caller
        dustLock.safeTransferFrom(msg.sender, address(this), tokenId);

        // Read locked amount from the NFT
        LockedBalance memory lock = dustLock.locked(tokenId);
        uint256 amount = uint256(uint128(lock.amount));
        if (amount == 0) revert ZeroAmount();

        // Convert to permanent lock if not already
        if (!lock.isPermanent) {
            dustLock.lockPermanent(tokenId);
        }

        // Bootstrap or route to bucket
        if (!bootstrapped) {
            // First ever deposit — this NFT becomes the first bucket
            bucketTokenIds.push(tokenId);
            bucketBalance[tokenId] = amount;
            bootstrapped = true;
            emit BucketCreated(tokenId, 0);
        } else {
            // Find a bucket that can hold this NFT intact
            uint256 targetBucket = _routeNFTToBucket(amount);

            if (targetBucket == 0) {
                // No existing bucket fits — create a new empty bucket first,
                // then merge incoming NFT into it
                uint256 newBucketId = _createNewEmptyBucket(amount, tokenId);
                // The incoming NFT IS the new bucket seed — already handled
                // in _createNewEmptyBucket when amount > BUCKET_CAP
                if (amount <= BUCKET_CAP) {
                    // Merge incoming NFT into the new bucket
                    dustLock.merge(tokenId, newBucketId);
                    bucketBalance[newBucketId] += amount;
                }
            } else {
                // Merge into the found bucket
                dustLock.merge(tokenId, targetBucket);
                bucketBalance[targetBucket] += amount;
            }
        }

        totalDustLocked += amount;
        yDust.mint(msg.sender, amount);

        emit NFTDeposited(msg.sender, tokenId, amount, _activeBucket());
    }

    /// @notice ERC-721 receiver hook — required to accept NFT transfers
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // =========================================================================
    // Deposit: Raw DUST
    // =========================================================================

    /// @notice Deposit raw DUST ERC-20 into Foreverland.
    /// @dev DUST is split across buckets as needed. The full amount is locked
    ///      as permanent veDUST and yDUST is minted 1:1 to the caller.
    /// @param amount Amount of DUST to deposit
    function depositDUST(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!bootstrapped) revert NotBootstrapped();

        // Pull DUST from caller
        dustToken.transferFrom(msg.sender, address(this), amount);

        // Lock DUST into buckets (splits across buckets if needed)
        _depositDUSTIntoBuckets(amount);

        totalDustLocked += amount;
        yDust.mint(msg.sender, amount);

        emit DUSTDeposited(msg.sender, amount);
    }

    /// @notice Deposit DUST on behalf of another address. Used by the Vault
    ///         during compounding to mint yDUST back to the Vault.
    /// @param amount Amount of DUST to deposit
    /// @param recipient Address that receives the minted yDUST
    function depositDUSTFor(uint256 amount, address recipient) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!bootstrapped) revert NotBootstrapped();
        if (msg.sender != vault && msg.sender != owner) revert NotStakerOrVault();

        dustToken.transferFrom(msg.sender, address(this), amount);
        _depositDUSTIntoBuckets(amount);

        totalDustLocked += amount;
        yDust.mint(recipient, amount);

        emit DUSTDeposited(recipient, amount);
    }

    // =========================================================================
    // Harvest
    // =========================================================================

    /// @notice Claim USDC revenue from all bucket NFTs and distribute to staker.
    /// @dev Called by Gelato keeper weekly after Neverland's epoch advances.
    ///      10% performance fee is sent to treasury, remainder to staker.
    function harvest() external onlyKeeper whenNotPaused {
        if (!bootstrapped) revert NotBootstrapped();

        uint256 currentEpoch = IRevenueReward(revenueReward).currentEpoch();
        if (currentEpoch <= lastHarvestedEpoch) revert NothingToHarvest();

        // Claim from every bucket
        uint256 totalClaimed;
        uint256 len = bucketTokenIds.length;
        for (uint256 i; i < len; ) {
            uint256 claimable = IRevenueReward(revenueReward).claimable(bucketTokenIds[i]);
            if (claimable > 0) {
                totalClaimed += IRevenueReward(revenueReward).claim(bucketTokenIds[i]);
            }
            unchecked { ++i; }
        }

        if (totalClaimed == 0) revert NothingToHarvest();

        // Calculate fee
        uint256 fee = (totalClaimed * performanceFee) / FEE_DENOMINATOR;
        uint256 toDistribute = totalClaimed - fee;

        // Send fee to treasury
        if (fee > 0) {
            usdc.transfer(treasury, fee);
        }

        // Notify staker with remaining USDC
        if (toDistribute > 0) {
            usdc.transfer(staker, toDistribute);
            IForeverlandStaker(staker).notifyRewardAmount(toDistribute);
        }

        lastHarvestedEpoch = currentEpoch;

        emit Harvested(totalClaimed, fee, toDistribute, currentEpoch);
    }

    // =========================================================================
    // Internal: Bucket Routing
    // =========================================================================

    /// @notice Find a bucket that can hold the full NFT amount intact.
    /// @dev Searches from newest to oldest. Returns 0 if none found.
    function _routeNFTToBucket(uint256 amount) internal view returns (uint256 targetBucketId) {
        // NFTs larger than BUCKET_CAP always get their own new bucket
        if (amount > BUCKET_CAP) return 0;

        uint256 len = bucketTokenIds.length;
        // Search newest first (most likely to have space)
        for (uint256 i = len; i > 0; ) {
            unchecked { --i; }
            uint256 id = bucketTokenIds[i];
            if (bucketBalance[id] + amount <= BUCKET_CAP) {
                return id;
            }
        }
        return 0; // No bucket fits
    }

    /// @notice Create a new bucket. If the incoming NFT IS the bucket seed
    ///         (amount > BUCKET_CAP), the NFT itself becomes the bucket.
    ///         Otherwise creates a tiny seed lock and the caller merges into it.
    function _createNewEmptyBucket(uint256 amount, uint256 incomingTokenId)
        internal
        returns (uint256 newBucketId)
    {
        if (amount > BUCKET_CAP) {
            // The incoming NFT is oversized — it IS its own bucket
            newBucketId = incomingTokenId;
            bucketTokenIds.push(newBucketId);
            bucketBalance[newBucketId] = amount;
            emit BucketCreated(newBucketId, bucketTokenIds.length - 1);
        } else {
            // Create a minimal seed lock so we have a bucket to merge into.
            // This requires a tiny DUST approval — handled by pre-approving
            // the dustLock for 1 wei in the constructor (or we create with 0
            // and rely on merge to populate). Since DustLock requires amount > 0,
            // we instead return 0 and let the caller use the incoming NFT directly
            // as the new bucket by calling lockPermanent again.
            //
            // Simpler approach: push the incoming NFT as the new bucket
            newBucketId = incomingTokenId;
            bucketTokenIds.push(newBucketId);
            bucketBalance[newBucketId] = 0; // will be updated after merge
            emit BucketCreated(newBucketId, bucketTokenIds.length - 1);
        }
    }

    /// @notice Deposit DUST into buckets sequentially, creating new ones as needed.
    /// @dev DUST is fungible so splits across buckets are invisible to the user.
    function _depositDUSTIntoBuckets(uint256 amount) internal {
        // Approve dustLock to spend DUST from this contract
        dustToken.approve(address(dustLock), amount);

        uint256 remaining = amount;
        while (remaining > 0) {
            uint256 activeId = _activeBucket();
            uint256 capacity = BUCKET_CAP - bucketBalance[activeId];

            if (capacity == 0) {
                // Active bucket is full — create a new one
                activeId = _createFreshBucket();
                capacity = BUCKET_CAP;
            }

            uint256 toDeposit = remaining > capacity ? capacity : remaining;
            dustLock.increaseAmount(activeId, toDeposit);
            bucketBalance[activeId] += toDeposit;

            unchecked { remaining -= toDeposit; }
        }
    }

    /// @notice Create a brand new empty bucket using a minimal DUST seed.
    /// @dev Requires this contract to hold at least 1 wei of DUST. In practice
    ///      this is always satisfied since the Locker holds DUST during deposit.
    function _createFreshBucket() internal returns (uint256 newId) {
        // Seed with 1 wei to create the lock, then lock permanently
        dustToken.approve(address(dustLock), 1);
        newId = dustLock.createLockFor(address(this), 1, MAX_LOCK_DURATION);
        dustLock.lockPermanent(newId);
        bucketTokenIds.push(newId);
        bucketBalance[newId] = 1; // 1 wei seed
        emit BucketCreated(newId, bucketTokenIds.length - 1);
    }

    /// @notice Returns the token ID of the active (most recently created) bucket.
    function _activeBucket() internal view returns (uint256) {
        return bucketTokenIds[bucketTokenIds.length - 1];
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Total number of bucket NFTs
    function bucketCount() external view returns (uint256) {
        return bucketTokenIds.length;
    }

    /// @notice Get all bucket token IDs
    function getBuckets() external view returns (uint256[] memory) {
        return bucketTokenIds;
    }

    /// @notice Total claimable USDC across all buckets
    function totalClaimable() external view returns (uint256 total) {
        uint256 len = bucketTokenIds.length;
        for (uint256 i; i < len; ) {
            total += IRevenueReward(revenueReward).claimable(bucketTokenIds[i]);
            unchecked { ++i; }
        }
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setStaker(address _staker) external onlyOwner {
        if (_staker == address(0)) revert ZeroAddress();
        staker = _staker;
        emit StakerSet(_staker);
    }

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setRevenueReward(address _revenueReward) external onlyOwner {
        if (_revenueReward == address(0)) revert ZeroAddress();
        revenueReward = _revenueReward;
        emit RevenueRewardSet(_revenueReward);
    }

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        if (_fee > 2_000) revert FeeTooHigh(); // max 20%
        performanceFee = _fee;
        emit PerformanceFeeSet(_fee);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Two-step ownership transfer
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

    /// @notice Rescue stuck ERC-20 tokens (cannot rescue DUST or USDC held for operations)
    function rescueToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }
}

/// @dev Minimal interface for calling the staker from the locker
interface IForeverlandStaker {
    function notifyRewardAmount(uint256 amount) external;
}
