// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ForeverlandResolver
/// @notice On-chain Gelato resolver for Foreverland's two automated tasks:
///         1. Weekly harvest from Neverland's RevenueReward → Staker
///         2. Weekly compound from Staker USDC → more yDUST in Vault
///
/// @dev Gelato's off-chain nodes call checker() at each block.
///      If canExec = true, they submit the transaction with execPayload.
///      The actual swap route (DEX vs NFT) and calldata for compound() is
///      built by the off-chain TypeScript Web3 Function — this contract
///      only handles the harvest trigger.
///
///      Gelato Web3 Function (TypeScript) handles:
///        - Querying Kuru and Uniswap V3 for best USDC→DUST quote
///        - Monitoring OpenSea/Blur for discounted veDUST NFTs
///        - Selecting best route and encoding calldata
///        - Calling vault.compoundViaDEX() or vault.compoundViaNFT()
contract ForeverlandResolver {
    // =========================================================================
    // Immutables
    // =========================================================================

    address public immutable locker;
    address public immutable vault;

    // =========================================================================
    // Interfaces (minimal)
    // =========================================================================

    interface ILockerView {
        function lastHarvestedEpoch() external view returns (uint256);
        function bootstrapped() external view returns (bool);
        function paused() external view returns (bool);
    }

    interface IRevenueRewardView {
        function currentEpoch() external view returns (uint256);
    }

    interface IVaultView {
        function pendingUSDC() external view returns (uint256);
        function minCompoundThreshold() external view returns (uint256);
    }

    address public immutable revenueReward;
    uint256 public immutable minCompoundThreshold;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _locker,
        address _vault,
        address _revenueReward
    ) {
        locker         = _locker;
        vault          = _vault;
        revenueReward  = _revenueReward;
    }

    // =========================================================================
    // Gelato Checker
    // =========================================================================

    /// @notice Gelato calls this to determine if harvest should be executed.
    /// @return canExec True if harvest should be called
    /// @return execPayload Encoded call to locker.harvest()
    function checkerHarvest()
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        ILockerView l = ILockerView(locker);

        // Don't execute if paused or not yet bootstrapped
        if (l.paused() || !l.bootstrapped()) {
            return (false, bytes("Locker not ready"));
        }

        uint256 currentEpoch = IRevenueRewardView(revenueReward).currentEpoch();
        uint256 lastEpoch    = l.lastHarvestedEpoch();

        if (currentEpoch > lastEpoch) {
            return (
                true,
                abi.encodeWithSignature("harvest()")
            );
        }

        return (false, bytes("Already harvested this epoch"));
    }

    /// @notice Gelato calls this to determine if compound threshold is met.
    /// @dev The actual compound calldata (route + swapData) is built by the
    ///      off-chain Web3 Function TypeScript script, not here.
    /// @return canExec True if compound should be called
    /// @return execPayload Empty — Web3 Function builds the real payload
    function checkerCompound()
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        IVaultView v = IVaultView(vault);
        uint256 pending   = v.pendingUSDC();
        uint256 threshold = v.minCompoundThreshold();

        if (pending >= threshold) {
            // Signal to Web3 Function that it should build and submit compound()
            return (true, bytes("Compound threshold met"));
        }

        return (false, bytes("Below compound threshold"));
    }
}
