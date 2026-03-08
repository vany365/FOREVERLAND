// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title yDUST
/// @notice Liquid receipt token for Foreverland. 1 yDUST = 1 DUST permanently
///         locked inside Foreverland's veDUST bucket NFTs.
/// @dev Minting and burning are restricted to the ForeverlandLocker contract.
///      yDUST is fully transferable and tradeable with no restrictions.
contract yDUST {
    // =========================================================================
    // ERC-20 State
    // =========================================================================

    string public constant name     = "yDUST";
    string public constant symbol   = "yDUST";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // =========================================================================
    // Access Control
    // =========================================================================

    address public locker;
    address public pendingLocker;
    address public owner;

    // =========================================================================
    // Events
    // =========================================================================

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event LockerSet(address indexed oldLocker, address indexed newLocker);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotLocker();
    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _owner The multisig address that controls this contract initially
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyLocker() {
        if (msg.sender != locker) revert NotLocker();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // =========================================================================
    // ERC-20 Core
    // =========================================================================

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
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
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - amount; }
        }

        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to]   += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    // =========================================================================
    // Mint / Burn — Locker only
    // =========================================================================

    /// @notice Mint yDUST to a recipient. Called by the Locker on every deposit.
    /// @param to Recipient address
    /// @param amount Amount of yDUST to mint (1:1 with DUST locked)
    function mint(address to, uint256 amount) external onlyLocker {
        if (to == address(0)) revert ZeroAddress();
        unchecked {
            totalSupply    += amount;
            balanceOf[to]  += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn yDUST from an address. Reserved for future redemption paths.
    /// @param from Address to burn from
    /// @param amount Amount of yDUST to burn
    function burn(address from, uint256 amount) external onlyLocker {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] -= amount;
            totalSupply     -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Set the locker address. Can only be called once after deployment.
    /// @param _locker Address of the ForeverlandLocker contract
    function setLocker(address _locker) external onlyOwner {
        if (_locker == address(0)) revert ZeroAddress();
        address old = locker;
        locker = _locker;
        emit LockerSet(old, _locker);
    }

    /// @notice Transfer ownership to a new address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
