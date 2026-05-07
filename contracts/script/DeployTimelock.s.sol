// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title DeployTimelock
/// @notice Deploys an OpenZeppelin TimelockController and initiates ownership
///         transfer of AvocadoVault + AvocadoLending to the timelock.
///
/// @dev Because both contracts use Ownable2Step, this script only *proposes*
///      the transfer via `transferOwnership(timelock)`. The timelock must then
///      schedule & execute `acceptOwnership()` on each contract to finalize.
///
/// Usage (Arbitrum Sepolia):
///   forge script script/DeployTimelock.s.sol:DeployTimelock \
///     --rpc-url arbitrum_sepolia \
///     --broadcast \
///     -vvvv
///
/// Usage (Arbitrum One mainnet):
///   forge script script/DeployTimelock.s.sol:DeployTimelock \
///     --rpc-url arbitrum \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Required env vars:
///   PRIVATE_KEY          — deployer / current owner private key
///   VAULT_ADDRESS        — deployed AvocadoVault address
///   LENDING_ADDRESS      — deployed AvocadoLending address
///   PROPOSER_ADDRESS     — (optional) timelock proposer; defaults to deployer
///   EXECUTOR_ADDRESS     — (optional) timelock executor; defaults to deployer
contract DeployTimelock is Script {
    /// @notice 48-hour minimum delay for all timelock operations
    uint256 constant MIN_DELAY = 48 hours;

    function run() external {
        // ── Load env ─────────────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address vaultAddr   = vm.envAddress("VAULT_ADDRESS");
        address lendingAddr = vm.envAddress("LENDING_ADDRESS");

        address proposer    = vm.envOr("PROPOSER_ADDRESS", deployer);
        address executor    = vm.envOr("EXECUTOR_ADDRESS", deployer);

        console.log("Deployer:  ", deployer);
        console.log("Vault:     ", vaultAddr);
        console.log("Lending:   ", lendingAddr);
        console.log("Proposer:  ", proposer);
        console.log("Executor:  ", executor);
        console.log("Min delay: ", MIN_DELAY, "seconds (48 hours)");

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy TimelockController ─────────────────────────────────────
        // Proposers array: only the designated proposer
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        // Executors array: only the designated executor
        address[] memory executors = new address[](1);
        executors[0] = executor;

        // Admin: address(0) — renounce admin role immediately on deploy
        TimelockController timelock = new TimelockController(
            MIN_DELAY,
            proposers,
            executors,
            address(0) // no admin — role is renounced at deploy
        );

        console.log("\nTimelockController deployed at:", address(timelock));

        // ── 2. Transfer vault ownership to timelock (step 1 of 2) ────────────
        Ownable2Step vault = Ownable2Step(vaultAddr);
        vault.transferOwnership(address(timelock));
        console.log("Vault ownership transfer proposed -> timelock");

        // ── 3. Transfer lending ownership to timelock (step 1 of 2) ──────────
        Ownable2Step lending = Ownable2Step(lendingAddr);
        lending.transferOwnership(address(timelock));
        console.log("Lending ownership transfer proposed -> timelock");

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────────────────
        console.log("\n=== Timelock Deployment Summary ===");
        console.log("TimelockController:", address(timelock));
        console.log("Min delay:         ", MIN_DELAY, "seconds");
        console.log("Proposer:          ", proposer);
        console.log("Executor:          ", executor);
        console.log("Admin role:         RENOUNCED (address(0))");
        console.log("====================================");
        console.log("\nNEXT STEPS:");
        console.log("  1. Schedule acceptOwnership() on the timelock for the vault:");
        console.log("     timelock.schedule(vault, 0, abi.encodeCall(Ownable2Step.acceptOwnership, ()), 0, 0, MIN_DELAY)");
        console.log("  2. After 48h, execute the scheduled call to finalize vault ownership");
        console.log("  3. Repeat for lending contract");
        console.log("  4. Verify: vault.owner() == timelock && lending.owner() == timelock");
    }
}
