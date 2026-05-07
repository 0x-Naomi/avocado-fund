// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AvocadoVault} from "../src/AvocadoVault.sol";
import {AvocadoLending} from "../src/AvocadoLending.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mock USDC for local testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title DeployLocal
/// @notice Deploys contracts to a local Anvil node and seeds test state.
///
/// Usage (one terminal):
///   anvil --port 8545
///
/// Another terminal:
///   cd avocado-fund/contracts
///   forge script script/DeployLocal.s.sol:DeployLocal \
///     --rpc-url http://localhost:8545 \
///     --broadcast -vvvv
///
/// Output: paste addresses into src/lib/contracts.ts under chainId 31337
contract DeployLocal is Script {
    // Anvil default accounts (deterministic)
    address constant DEPLOYER     = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ALICE        = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant BOB          = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant BORROWER1    = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant BORROWER2    = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        // Use Anvil's first account private key
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy mock USDC ───────────────────────────────────────────────
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC:", address(usdc));

        // ── 2. Deploy Vault ───────────────────────────────────────────────────
        AvocadoVault vault = new AvocadoVault(
            address(usdc),
            DEPLOYER,          // owner
            DEPLOYER,          // fee recipient
            4_000_000e6        // $4M cap
        );
        console.log("AvocadoVault:", address(vault));

        // ── 3. Deploy Lending ─────────────────────────────────────────────────
        AvocadoLending lending = new AvocadoLending(
            address(vault),
            address(usdc),
            DEPLOYER,
            1_200              // 12% APR
        );
        console.log("AvocadoLending:", address(lending));

        // ── 4. Wire up ────────────────────────────────────────────────────────
        vault.setLendingContract(address(lending));

        // ── 5. Mint USDC to test wallets ──────────────────────────────────────
        usdc.mint(DEPLOYER,   500_000e6);   // $500K
        usdc.mint(ALICE,      100_000e6);   // $100K
        usdc.mint(BOB,         50_000e6);   // $50K
        usdc.mint(BORROWER1,    1_000e6);   // $1K (for repayments)
        usdc.mint(BORROWER2,    1_000e6);

        // ── 6. Seed vault with initial deposits (from deployer) ───────────────
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, DEPLOYER);   // $200K seeded

        // ── 7. Deploy 90% to lending ──────────────────────────────────────────
        vault.deployToLending(180_000e6);

        // ── 8. Approve test borrowers ─────────────────────────────────────────
        lending.approveBorrower(BORROWER1, 50_000e6);   // $50K credit limit
        lending.approveBorrower(BORROWER2, 25_000e6);   // $25K credit limit

        vm.stopBroadcast();

        // ─── Print addresses for .env.local ──────────────────────────────────
        console.log("\n=== COPY TO src/lib/contracts.ts (chainId 31337) ===");
        console.log("vault:   ", address(vault));
        console.log("lending: ", address(lending));
        console.log("usdc:    ", address(usdc));
        console.log("====================================================");
        console.log("\nTest accounts (Anvil defaults, 10000 ETH each):");
        console.log("ALICE   ", ALICE,    "  100,000 USDC");
        console.log("BOB     ", BOB,      "   50,000 USDC");
        console.log("BORROWER1", BORROWER1, "  50,000 credit limit");
    }
}
