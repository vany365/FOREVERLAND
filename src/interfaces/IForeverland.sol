// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Represents the lock state of a veDUST NFT
struct LockedBalance {
    int128 amount;
    uint256 end;        // unlock timestamp (0 if permanent)
    bool isPermanent;
}

/// @notice Interface for Neverland's DustLock contract (veDUST NFT)
/// @dev Proxy at 0xbb4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C on Monad Mainnet
interface IDustLock {
    /// @notice Create a new time-locked veDUST NFT
    /// @param value Amount of DUST to lock
    /// @param lockDuration Duration in seconds to lock
    /// @return tokenId The newly minted NFT token ID
    function createLock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);

    /// @notice Create a new time-locked veDUST NFT for a specific recipient
    /// @param to Recipient of the new NFT
    /// @param value Amount of DUST to lock
    /// @param lockDuration Duration in seconds to lock
    /// @return tokenId The newly minted NFT token ID
    function createLockFor(address to, uint256 value, uint256 lockDuration) external returns (uint256 tokenId);

    /// @notice Add more DUST to an existing lock without changing duration
    /// @param tokenId The veDUST NFT to increase
    /// @param value Amount of additional DUST to add
    function increaseAmount(uint256 tokenId, uint256 value) external;

    /// @notice Extend the unlock time of an existing time-lock
    /// @param tokenId The veDUST NFT to extend
    /// @param lockDuration New duration from now
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;

    /// @notice Convert a time-locked NFT to a permanent (infinite) lock
    /// @dev Voting power becomes static at 1:1 with locked DUST amount
    /// @param tokenId The veDUST NFT to permanently lock
    function lockPermanent(uint256 tokenId) external;

    /// @notice Remove permanent lock status (back to time-lock, required before withdraw)
    /// @param tokenId The veDUST NFT to unlock from permanent status
    function unlockPermanent(uint256 tokenId) external;

    /// @notice Merge source NFT into destination NFT
    /// @dev Source NFT is burned. Both must be permanent locks or same end time.
    ///      Any self-repayment enrollment is cleared on merge.
    /// @param from Token ID of the source NFT (will be burned)
    /// @param to Token ID of the destination NFT (will receive DUST)
    function merge(uint256 from, uint256 to) external;

    /// @notice Withdraw DUST from an expired time-lock
    /// @param tokenId The expired veDUST NFT to withdraw from
    function withdraw(uint256 tokenId) external;

    /// @notice Early withdraw with penalty (before lock expiry)
    /// @param tokenId The veDUST NFT to early withdraw from
    function earlyWithdraw(uint256 tokenId) external;

    /// @notice Get the locked balance info for a veDUST NFT
    /// @param tokenId The veDUST NFT to query
    /// @return LockedBalance struct with amount, end time, and isPermanent flag
    function locked(uint256 tokenId) external view returns (LockedBalance memory);

    /// @notice Get the current voting power of a veDUST NFT
    /// @param tokenId The veDUST NFT to query
    /// @return Voting power (equal to locked amount for permanent locks)
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    /// @notice Get the owner of a veDUST NFT
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Transfer a veDUST NFT
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Approve operator for all NFTs
    function setApprovalForAll(address operator, bool approved) external;

    /// @notice Check if operator is approved for all NFTs of owner
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice Get approval for a specific token
    function getApproved(uint256 tokenId) external view returns (address);

    /// @notice Approve a specific token to an address
    function approve(address to, uint256 tokenId) external;
}

/// @notice Interface for Neverland's revenue reward distributor
interface IRevenueReward {
    /// @notice Claim USDC revenue for a specific veDUST NFT
    /// @param tokenId The veDUST NFT to claim rewards for
    /// @return amount The USDC amount claimed
    function claim(uint256 tokenId) external returns (uint256 amount);

    /// @notice Get claimable USDC for a specific veDUST NFT
    /// @param tokenId The veDUST NFT to query
    /// @return amount Claimable USDC amount
    function claimable(uint256 tokenId) external view returns (uint256 amount);

    /// @notice Get the current epoch number
    function currentEpoch() external view returns (uint256);
}

/// @notice Minimal ERC-20 interface
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice Generic DEX swap router interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);

    /// @notice Generic swap with arbitrary calldata (for aggregators like Kuru)
    function swap(bytes calldata data) external returns (uint256 amountOut);
}

/// @notice Seaport interface for NFT marketplace purchases
interface ISeaport {
    struct OfferItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct ConsiderationItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address payable recipient;
    }

    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        uint8 orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }

    struct Order {
        OrderParameters parameters;
        bytes signature;
    }

    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey)
        external
        payable
        returns (bool fulfilled);
}

/// @notice Gelato Automate interface for task creation
interface IAutomate {
    function createTask(
        address execAddress,
        bytes calldata execDataOrSelector,
        tuple(uint8 taskType, bytes taskData) calldata moduleData,
        address feeToken
    ) external returns (bytes32 taskId);
}
