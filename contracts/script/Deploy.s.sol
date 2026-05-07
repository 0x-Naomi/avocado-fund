// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AvocadoVault} from "../src/AvocadoVault.sol";
import {AvocadoLending} from "../src/AvocadoLending.sol";

/// @title Deploy
/// @notice Deploys AvocadoVault + AvocadoLending to Arbitrum One, Arbitrum Sepolia, or legacy Base
///
/// Usage (Arbitrum Sepolia testnet):
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url arbitrum_sepolia \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Usage (Arbitrum One mainnet):
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url arbitrum \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Required env vars:
///   PRIVATE_KEY          — deployer private key (use hardware wallet in prod)
///   OWNER_ADDRESS        — multisig that will own the contracts post-deploy
///   FEE_RECIPIENT        — address to receive protocol fees
///   VAULT_CAP            — initial vault cap in USDC base units (e.g. 5_000_000_000_000 = $5M)
///   BORROW_RATE_BPS      — initial borrow APR in basis points (e.g. 1200 = 12%)
contract Deploy is Script {
    // ─── Addresses ────────────────────────────────────────────────────────────

    // USDC on Arbitrum One (native USDC)
    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // USDC on Arbitrum Sepolia (test USDC)
    address constant USDC_ARBITRUM_SEPOLIA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    // USDC on Base mainnet (legacy)
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // USDC on Base Sepolia (legacy testnet)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        // Load env
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner       = vm.envOr("OWNER_ADDRESS", vm.addr(deployerKey));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", vm.addr(deployerKey));
        uint256 vaultCap    = vm.envOr("VAULT_CAP", uint256(5_000_000_000_000)); // $5M default
        uint256 borrowRate  = vm.envOr("BORROW_RATE_BPS", uint256(1_200));       // 12% APR default

        // Detect network
        address usdc;
        if (block.chainid == 42161) {
            usdc = USDC_ARBITRUM;
            console.log("Deploying to Arbitrum One (mainnet)");
        } else if (block.chainid == 421614) {
            usdc = USDC_ARBITRUM_SEPOLIA;
            console.log("Deploying to Arbitrum Sepolia");
        } else if (block.chainid == 8453) {
            usdc = USDC_BASE;
            console.log("Deploying to Base mainnet (legacy)");
        } else if (block.chainid == 84532) {
            usdc = USDC_BASE_SEPOLIA;
            console.log("Deploying to Base Sepolia (legacy)");
        } else {
            // Local / Anvil: deploy a mock USDC (handled externally)
            usdc = vm.envAddress("USDC_ADDRESS");
            console.log("Deploying to local/custom network, USDC:", usdc);
        }

        console.log("Deployer:", vm.addr(deployerKey));
        console.log("Owner:   ", owner);
        console.log("FeeRecip:", feeRecipient);
        console.log("VaultCap:", vaultCap);
        console.log("BorrowRate:", borrowRate, "bps");

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy Vault ───────────────────────────────────────────────────
        AvocadoVault avaultVault = new AvocadoVault(
            usdc,
            owner,
            feeRecipient,
            vaultCap
        );

        // ── 2. Deploy Lending ─────────────────────────────────────────────────
        AvocadoLending lending = new AvocadoLending(
            address(avaultVault),
            usdc,
            owner,
            borrowRate
        );

        // ── 3. Wire up: set lending contract on vault ─────────────────────────
        // (This call must come from the vault owner — here the deployer, then
        //  ownership is transferred to the multisig after setup)
        avaultVault.setLendingContract(address(lending));

        vm.stopBroadcast();

        // ─── Log deployed addresses ───────────────────────────────────────────
        console.log("\n=== Avocado Fund Deployment ===");
        console.log("AvocadoVault   :", address(avaultVault));
        console.log("AvocadoLending :", address(lending));
        console.log("USDC asset     :", usdc);
        console.log("Owner          :", owner);
        console.log("================================");
        console.log("\nNEXT STEPS:");
        console.log("1. Transfer ownership to multisig: avaultVault.transferOwnership(multisig)");
        console.log("2. Accept ownership from multisig: avaultVault.acceptOwnership()");
        console.log("3. Approve initial borrowers via: lending.approveBorrower(addr, limit)");
        console.log("4. Deploy capital to lending:     avaultVault.deployToLending(amount)");
    }
}
