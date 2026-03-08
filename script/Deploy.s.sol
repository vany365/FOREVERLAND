// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/yDUST.sol";
import "../src/ForeverlandLocker.sol";
import "../src/ForeverlandStaker.sol";
import "../src/ForeverlandVault.sol";
import "../src/ForeverlandResolver.sol";

/// @title DeployForeverland
/// @notice Deploys the full Foreverland protocol in the correct dependency order.
///
/// @dev Deployment order:
///   1. yDUST           (no dependencies)
///   2. ForeverlandLocker (depends on yDUST)
///   3. yDUST.setLocker  (wire locker → yDUST)
///   4. ForeverlandStaker (depends on yDUST + Locker)
///   5. Locker.setStaker  (wire staker → locker)
///   6. ForeverlandVault  (depends on yDUST + Staker + Locker)
///   7. Locker.setVault   (wire vault → locker)
///   8. Staker.setWhitelisted(vault, true)
///   9. ForeverlandResolver
///
/// Usage:
///   forge script script/Deploy.s.sol:DeployForeverland \
///     --rpc-url monad \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify
contract DeployForeverland is Script {
    // =========================================================
    // Neverland Mainnet Addresses (Monad)
    // =========================================================
    address constant DUST_LOCK      = 0xBB4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C;
    address constant DUST_TOKEN     = 0xad96c3dffcd6374294e2573a7fbba96097cc8d7c;
    address constant REVENUE_REWARD = address(0); // TODO: fill in before deploy
    address constant USDC           = address(0); // TODO: fill in USDC on Monad

    function run() external {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address keeper   = vm.envAddress("GELATO_PROXY"); // Gelato dedicated proxy
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");

        require(multisig      != address(0), "MULTISIG_ADDRESS not set");
        require(REVENUE_REWARD != address(0), "REVENUE_REWARD not set");
        require(USDC           != address(0), "USDC not set");

        vm.startBroadcast(pk);

        // ── 1. Deploy yDUST ──────────────────────────────────
        yDUST ydust = new yDUST(multisig);
        console2.log("yDUST deployed at:            ", address(ydust));

        // ── 2. Deploy ForeverlandLocker ───────────────────────
        ForeverlandLocker locker = new ForeverlandLocker(
            multisig,
            DUST_LOCK,
            DUST_TOKEN,
            USDC,
            address(ydust),
            multisig,       // treasury
            REVENUE_REWARD
        );
        console2.log("ForeverlandLocker deployed at:", address(locker));

        // ── 3. Wire yDUST → Locker ────────────────────────────
        // NOTE: This call must be made by the multisig if deployer != multisig
        // If deployer == multisig, uncomment:
        // ydust.setLocker(address(locker));

        // ── 4. Deploy ForeverlandStaker ───────────────────────
        ForeverlandStaker staker = new ForeverlandStaker(
            multisig,
            address(ydust),
            USDC,
            address(locker)
        );
        console2.log("ForeverlandStaker deployed at:", address(staker));

        // ── 5. Deploy ForeverlandVault ────────────────────────
        ForeverlandVault vault = new ForeverlandVault(
            multisig,
            address(ydust),
            USDC,
            address(locker),
            address(staker),
            DUST_TOKEN,
            multisig        // treasury
        );
        console2.log("ForeverlandVault deployed at: ", address(vault));

        // ── 6. Deploy ForeverlandResolver ─────────────────────
        ForeverlandResolver resolver = new ForeverlandResolver(
            address(locker),
            address(vault),
            REVENUE_REWARD
        );
        console2.log("ForeverlandResolver deployed at:", address(resolver));

        vm.stopBroadcast();

        // ── Post-deploy wiring (must be done by multisig) ─────
        console2.log("\n=== POST-DEPLOY MULTISIG ACTIONS REQUIRED ===");
        console2.log("1. ydust.setLocker(locker)");
        console2.log("2. locker.setStaker(staker)");
        console2.log("3. locker.setVault(vault)");
        console2.log("4. locker.setKeeper(gelatoProxy)");
        console2.log("5. vault.setKeeper(gelatoProxy)");
        console2.log("6. staker.setWhitelisted(vault, true)");
        console2.log("7. Register Gelato tasks pointing at resolver");
        console2.log("8. Fund Gelato balance with MON");
        console2.log("9. Seed first deposit to bootstrap master bucket NFT");
        console2.log("=============================================\n");

        // Print addresses for easy copy
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("yDUST:              ", address(ydust));
        console2.log("ForeverlandLocker:  ", address(locker));
        console2.log("ForeverlandStaker:  ", address(staker));
        console2.log("ForeverlandVault:   ", address(vault));
        console2.log("ForeverlandResolver:", address(resolver));
    }
}
