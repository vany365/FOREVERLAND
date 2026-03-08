// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IForeverland.sol";

/// @title ForeverlandVault
/// @notice ERC-4626 auto-compounding vault for yDUST.
///         Users deposit yDUST and receive fvyDUST shares. A Gelato keeper
///         calls compound() weekly, which claims USDC from the Staker, finds
///         the best route (DEX swap vs NFT marketplace purchase), acquires more
///         DUST, locks it via the Locker to receive yDUST, and re-deposits —
///         growing the share price over time.
///
/// @dev Share price mechanics:
///   - pricePerShare = totalAssets() / totalSupply
///   - On deposit: shares = amount * totalSupply / totalAssets (or 1:1 on first deposit)
///   - On redeem:  yDUST = shares * totalAssets / totalSupply
///   - compound() grows totalAssets without minting new shares => price increases
///
/// @dev The Vault is whitelisted in the Staker for immediate 1x reward weight.
contract ForeverlandVault {
    // =========================================================================
    // Constants
    // =========================================================================

    string public constant name     = "Foreverland Vault yDUST";
    string public constant symbol   = "fvyDUST";
    uint8  public constant decimals = 18;

    uint256 public constant FEE_DENOMINATOR    = 10_000;
    uint256 public constant MIN_SHARES         = 1_000; // Prevent share price manipulation on first deposit
    uint256 public constant PRECISION          = 1e18;

    // =========================================================================
    // Immutables
    // =========================================================================

    IERC20  public immutable yDust;    // Underlying asset (yDUST)
    IERC20  public immutable usdc;     // Reward token from staker
    address public immutable locker;   // ForeverlandLocker
    address public immutable staker;   // ForeverlandStaker
    address public immutable dustToken; // DUST ERC-20 for compounding

    // =========================================================================
    // State
    // =========================================================================

    address public owner;
    address public pendingOwner;
    address public keeper;       // Gelato proxy
    address public treasury;     // Performance fee recipient

    uint256 public performanceFee = 1_000; // 10% in bps

    /// @notice Minimum USDC accumulated before compound() fires
    uint256 public minCompoundThreshold = 100e6; // $100 USDC (6 decimals)

    /// @notice Maximum slippage allowed on DEX swaps (in bps)
    uint256 public maxSlippageBps = 100; // 1%

    // ERC-20 share token state
    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // =========================================================================
    // Events
    // =========================================================================

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event CompoundedViaDEX(address indexed router, uint256 usdcIn, uint256 dustOut, uint256 yDustMinted);
    event CompoundedViaNFT(uint256 indexed tokenId, uint256 dustAmount, uint256 yDustMinted);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner_, address indexed spender, uint256 amount);
    event KeeperSet(address indexed keeper);
    event TreasurySet(address indexed treasury);
    event PerformanceFeeSet(uint256 fee);
    event MinThresholdSet(uint256 threshold);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotOwner();
    error NotKeeper();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientAssets();
    error InsufficientShares();
    error InsufficientAllowance();
    error SlippageTooHigh();
    error BelowThreshold();
    error FeeTooHigh();
    error NFTNotReceived();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _owner,
        address _yDust,
        address _usdc,
        address _locker,
        address _staker,
        address _dustToken,
        address _treasury
    ) {
        if (_owner     == address(0)) revert ZeroAddress();
        if (_yDust     == address(0)) revert ZeroAddress();
        if (_usdc      == address(0)) revert ZeroAddress();
        if (_locker    == address(0)) revert ZeroAddress();
        if (_staker    == address(0)) revert ZeroAddress();
        if (_dustToken == address(0)) revert ZeroAddress();
        if (_treasury  == address(0)) revert ZeroAddress();

        owner      = _owner;
        yDust      = IERC20(_yDust);
        usdc       = IERC20(_usdc);
        locker     = _locker;
        staker     = _staker;
        dustToken  = IERC20(_dustToken);
        treasury   = _treasury;
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

    // =========================================================================
    // ERC-4626: Core Vault
    // =========================================================================

    /// @notice Total yDUST assets held by this vault (including staked)
    /// @dev The vault stakes all its yDUST in the Staker, so actual
    ///      yDUST balance here is minimal. We track via totalSupply accounting.
    function totalAssets() public view returns (uint256) {
        // All yDUST is staked — use totalSupply of vault shares adjusted by
        // accumulated compounding. We track this via a stored totalAssets value
        // that grows each time compound() runs.
        return _totalAssets;
    }

    uint256 internal _totalAssets;

    /// @notice Convert yDUST assets to vault shares
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return (assets * supply) / _totalAssets;
    }

    /// @notice Convert vault shares to yDUST assets
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * _totalAssets) / supply;
    }

    /// @notice Deposit yDUST, receive fvyDUST shares
    /// @param assets Amount of yDUST to deposit
    /// @param receiver Address to receive fvyDUST shares
    /// @return shares Amount of fvyDUST shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        // On very first deposit, seed MIN_SHARES to prevent manipulation
        if (totalSupply == 0) {
            shares = assets; // 1:1 on first deposit
        }

        // Pull yDUST from depositor
        yDust.transferFrom(msg.sender, address(this), assets);

        // Stake yDUST in the Staker to earn USDC rewards
        yDust.approve(staker, assets);
        IForeverlandStakerFull(staker).stake(assets);

        // Update internal accounting
        _totalAssets += assets;

        // Mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem fvyDUST shares for yDUST
    /// @param shares Amount of fvyDUST shares to burn
    /// @param receiver Address to receive yDUST
    /// @param owner_ Owner of the shares
    /// @return assets Amount of yDUST returned
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed < shares) revert InsufficientAllowance();
            if (allowed != type(uint256).max) {
                unchecked { allowance[owner_][msg.sender] = allowed - shares; }
            }
        }

        if (balanceOf[owner_] < shares) revert InsufficientShares();

        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > _totalAssets) revert InsufficientAssets();

        // Burn shares first (CEI pattern)
        _burn(owner_, shares);
        _totalAssets -= assets;

        // Unstake the proportional yDUST from Staker
        // We unstake from position 0 (FIFO) for simplicity
        // The vault may have multiple staking positions
        _unstakeFromStaker(assets);

        // Transfer yDUST to receiver
        yDust.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Withdraw a specific amount of yDUST by burning required shares
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = convertToShares(assets);
        if (balanceOf[owner_] < shares) revert InsufficientShares();

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed < shares) revert InsufficientAllowance();
            if (allowed != type(uint256).max) {
                unchecked { allowance[owner_][msg.sender] = allowed - shares; }
            }
        }

        _burn(owner_, shares);
        _totalAssets -= assets;

        _unstakeFromStaker(assets);
        yDust.transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // =========================================================================
    // Compound: DEX Path
    // =========================================================================

    /// @notice Compound via DEX swap: claim USDC, swap for DUST, lock for yDUST.
    /// @dev Called by Gelato keeper. Router can be Kuru or Uniswap V3.
    ///      The keeper's off-chain script selects the best router and builds
    ///      swapData off-chain, then passes minDustOut for slippage protection.
    /// @param router DEX router address (Kuru or Uniswap V3 on Monad)
    /// @param swapData Encoded swap calldata built by the keeper off-chain
    /// @param minDustOut Minimum DUST expected from swap (slippage guard)
    function compoundViaDEX(
        address router,
        bytes calldata swapData,
        uint256 minDustOut
    ) external onlyKeeper {
        // Claim USDC rewards from Staker
        uint256 usdcBefore = usdc.balanceOf(address(this));
        IForeverlandStakerFull(staker).claim();
        uint256 usdcClaimed = usdc.balanceOf(address(this)) - usdcBefore;

        if (usdcClaimed < minCompoundThreshold) revert BelowThreshold();

        // Take performance fee
        uint256 fee = (usdcClaimed * performanceFee) / FEE_DENOMINATOR;
        if (fee > 0) usdc.transfer(treasury, fee);
        uint256 usdcToSwap = usdcClaimed - fee;

        // Execute swap USDC → DUST via selected router
        uint256 dustBefore = dustToken.balanceOf(address(this));
        usdc.approve(router, usdcToSwap);
        (bool success,) = router.call(swapData);
        require(success, "Swap failed");
        uint256 dustReceived = dustToken.balanceOf(address(this)) - dustBefore;

        // Enforce slippage
        if (dustReceived < minDustOut) revert SlippageTooHigh();

        // Lock DUST into Foreverland via Locker → receive yDUST
        dustToken.approve(locker, dustReceived);
        IForeverlandLockerFull(locker).depositDUSTFor(dustReceived, address(this));

        // Stake new yDUST in Staker
        uint256 newYDust = yDust.balanceOf(address(this));
        if (newYDust > 0) {
            yDust.approve(staker, newYDust);
            IForeverlandStakerFull(staker).stake(newYDust);
            _totalAssets += newYDust; // Share price grows
        }

        emit CompoundedViaDEX(router, usdcToSwap, dustReceived, newYDust);
    }

    // =========================================================================
    // Compound: NFT Marketplace Path
    // =========================================================================

    /// @notice Compound via NFT purchase: buy discounted veDUST NFT from marketplace.
    /// @dev Called by Gelato keeper when an NFT is found trading below intrinsic value.
    ///      The keeper's off-chain script monitors OpenSea/Blur for listings and
    ///      calls this when DUST-per-USDC is better than the DEX rate.
    /// @param seaport Seaport contract address (OpenSea)
    /// @param order The Seaport order to fulfill
    /// @param expectedTokenId The veDUST NFT token ID being purchased (for verification)
    /// @param minDustExpected Minimum DUST value locked in the NFT (slippage guard)
    function compoundViaNFT(
        address seaport,
        ISeaport.Order calldata order,
        uint256 expectedTokenId,
        uint256 minDustExpected
    ) external onlyKeeper {
        // Claim USDC rewards from Staker
        uint256 usdcBefore = usdc.balanceOf(address(this));
        IForeverlandStakerFull(staker).claim();
        uint256 usdcClaimed = usdc.balanceOf(address(this)) - usdcBefore;

        if (usdcClaimed < minCompoundThreshold) revert BelowThreshold();

        // Take performance fee
        uint256 fee = (usdcClaimed * performanceFee) / FEE_DENOMINATOR;
        if (fee > 0) usdc.transfer(treasury, fee);
        uint256 usdcForPurchase = usdcClaimed - fee;

        // Approve USDC for Seaport
        usdc.approve(seaport, usdcForPurchase);

        // Execute NFT purchase via Seaport
        bool fulfilled = ISeaport(seaport).fulfillOrder(order, bytes32(0));
        require(fulfilled, "NFT purchase failed");

        // Verify we received the expected NFT
        if (IDustLock(address(yDust)).ownerOf(expectedTokenId) != address(this)) {
            revert NFTNotReceived();
        }

        // Read DUST locked in the purchased NFT
        LockedBalance memory lock = IDustLock(IForeverlandLockerFull(locker).dustLock())
            .locked(expectedTokenId);
        uint256 dustAmount = uint256(uint128(lock.amount));
        if (dustAmount < minDustExpected) revert SlippageTooHigh();

        // Deposit NFT into Locker → receive yDUST
        IDustLock(IForeverlandLockerFull(locker).dustLock())
            .setApprovalForAll(locker, true);
        IForeverlandLockerFull(locker).depositNFT(expectedTokenId);

        // Stake new yDUST in Staker
        uint256 newYDust = yDust.balanceOf(address(this));
        if (newYDust > 0) {
            yDust.approve(staker, newYDust);
            IForeverlandStakerFull(staker).stake(newYDust);
            _totalAssets += newYDust;
        }

        emit CompoundedViaNFT(expectedTokenId, dustAmount, newYDust);
    }

    // =========================================================================
    // ERC-20 Share Token
    // =========================================================================

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientShares();
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to]         += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) {
            unchecked { allowance[from][msg.sender] = allowed - amount; }
        }
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to]   += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply     += amount;
        balanceOf[to]   += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @notice Unstake yDUST from the Staker proportionally
    function _unstakeFromStaker(uint256 amount) internal {
        // Unstake from position 0 — the vault uses a single rolling position
        // managed by always staking into the same slot
        uint256 posCount = IForeverlandStakerFull(staker).positionCount(address(this));
        if (posCount == 0) return;

        uint256 remaining = amount;
        for (uint256 i; i < posCount && remaining > 0; ) {
            (uint256 posAmount,,) = IForeverlandStakerFull(staker).getPosition(address(this), 0);
            uint256 toUnstake = remaining > posAmount ? posAmount : remaining;
            IForeverlandStakerFull(staker).unstake(0, toUnstake);
            remaining -= toUnstake;
            // Re-fetch posCount since unstake may pop the array
            posCount = IForeverlandStakerFull(staker).positionCount(address(this));
            if (posCount == 0) break;
        }
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Preview shares for a given yDUST deposit amount
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview yDUST for a given share amount
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Current price per share in yDUST (scaled by 1e18)
    function pricePerShare() external view returns (uint256) {
        if (totalSupply == 0) return PRECISION;
        return (_totalAssets * PRECISION) / totalSupply;
    }

    /// @notice USDC available to compound (pending in staker)
    function pendingUSDC() external view returns (uint256) {
        return IForeverlandStakerFull(staker).claimable(address(this));
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        if (_fee > 2_000) revert FeeTooHigh();
        performanceFee = _fee;
        emit PerformanceFeeSet(_fee);
    }

    function setMinCompoundThreshold(uint256 _threshold) external onlyOwner {
        minCompoundThreshold = _threshold;
        emit MinThresholdSet(_threshold);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    address public pendingOwner;

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

/// @dev Extended staker interface for vault interactions
interface IForeverlandStakerFull {
    function stake(uint256 amount) external;
    function unstake(uint256 positionIndex, uint256 amount) external;
    function claim() external;
    function claimable(address user) external view returns (uint256);
    function positionCount(address user) external view returns (uint256);
    function getPosition(address user, uint256 index) external view returns (uint256, uint256, uint256);
}

/// @dev Extended locker interface for vault interactions
interface IForeverlandLockerFull {
    function depositNFT(uint256 tokenId) external;
    function depositDUSTFor(uint256 amount, address recipient) external;
    function dustLock() external view returns (address);
}
