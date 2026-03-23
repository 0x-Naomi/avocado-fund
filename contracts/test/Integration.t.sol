// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {AvocadoVault} from "../src/AvocadoVault.sol";
import {AvocadoLending} from "../src/AvocadoLending.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mock USDC ────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─── Full Protocol Integration Tests ─────────────────────────────────────────
//
// Covers the complete borrower/lender lifecycle:
//   Deposit → Deploy → Borrow → Time-travel → Repay → Recall → Fees → Withdraw
//
// Key invariant: after repayAll, the owner must call:
//   lending.returnFundsToVault(amount)  — sets ERC-20 approval from lending
//   vault.recallFromLending(amount)     — vault pulls USDC back from lending
// Only then can lenders redeem beyond the idle ratio.

contract IntegrationTest is Test {
    MockUSDC       public usdc;
    AvocadoVault   public vault;
    AvocadoLending public lending;

    address public owner     = makeAddr("owner");
    address public feeRecip  = makeAddr("feeRecipient");
    address public alice     = makeAddr("alice");      // lender
    address public bob       = makeAddr("bob");        // lender
    address public carol     = makeAddr("carol");      // lender (late joiner)
    address public borrowerA = makeAddr("borrowerA");
    address public borrowerB = makeAddr("borrowerB");

    uint256 constant VAULT_CAP   = 4_000_000e6;
    uint256 constant BORROW_RATE = 1_200;     // 12% APR
    uint256 constant YEAR        = 365 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc    = new MockUSDC();
        vault   = new AvocadoVault(address(usdc), owner, feeRecip, VAULT_CAP);
        lending = new AvocadoLending(address(vault), address(usdc), owner, BORROW_RATE);
        vault.setLendingContract(address(lending));
        vm.stopPrank();
    }

    // ─── Helper: recall all deployed USDC from lending back to vault ──────────
    function _recallAll() internal {
        uint256 deployed = vault.deployedAssets();
        if (deployed == 0) return;
        uint256 available = usdc.balanceOf(address(lending));
        uint256 recall = deployed < available ? deployed : available;
        vm.startPrank(owner);
        lending.returnFundsToVault(recall);
        vault.recallFromLending(recall);
        vm.stopPrank();
    }

    // ─── Test 1: Full happy-path lifecycle ────────────────────────────────────

    function test_FullLifecycle() public {
        // ── Step 1: Deposit ───────────────────────────────────────────────────
        usdc.mint(alice, 200_000e6);
        usdc.mint(bob,   100_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 200_000e6);
        uint256 aliceShares = vault.deposit(200_000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 100_000e6);
        uint256 bobShares = vault.deposit(100_000e6, bob);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 300_000e6);
        assertGt(aliceShares, bobShares);

        // ── Step 2: Deploy $270K to lending ───────────────────────────────────
        vm.prank(owner);
        vault.deployToLending(270_000e6);

        // ── Step 3: Approve & borrow ──────────────────────────────────────────
        vm.prank(owner);
        lending.approveBorrower(borrowerA, 150_000e6);
        vm.prank(owner);
        lending.approveBorrower(borrowerB, 80_000e6);

        vm.prank(borrowerA);
        lending.borrow(120_000e6);
        vm.prank(borrowerB);
        lending.borrow(60_000e6);

        assertEq(lending.totalPrincipal(), 180_000e6);

        // ── Step 4: 1 year passes ─────────────────────────────────────────────
        vm.warp(block.timestamp + YEAR);

        uint256 interestA = (120_000e6 * BORROW_RATE) / 10_000; // $14,400
        uint256 interestB = (60_000e6  * BORROW_RATE) / 10_000; // $7,200

        uint256 spBefore = vault.sharePrice();

        // ── Step 5: Both borrowers repay in full ──────────────────────────────
        usdc.mint(borrowerA, interestA + 1e6);
        vm.startPrank(borrowerA);
        usdc.approve(address(lending), 120_000e6 + interestA + 1e6);
        lending.repayAll();
        vm.stopPrank();

        usdc.mint(borrowerB, interestB + 1e6);
        vm.startPrank(borrowerB);
        usdc.approve(address(lending), 60_000e6 + interestB + 1e6);
        lending.repayAll();
        vm.stopPrank();

        assertGt(vault.sharePrice(), spBefore, "share price up after repay");

        // ── Step 6: Recall principal + interest from lending to vault ─────────
        _recallAll();

        // ── Step 7: Collect fees ──────────────────────────────────────────────
        uint256 feeSharesBefore = vault.balanceOf(feeRecip);
        vault.collectFees();
        assertGt(vault.balanceOf(feeRecip), feeSharesBefore);

        // ── Step 8: Alice and Bob redeem — they earned yield ──────────────────
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        vault.redeem(vault.maxRedeem(alice), alice, alice);
        vm.stopPrank();

        assertGt(usdc.balanceOf(alice) - aliceUsdcBefore, 200_000e6, "alice earned yield");

        vm.startPrank(bob);
        vault.redeem(vault.maxRedeem(bob), bob, bob);
        vm.stopPrank();

        assertGt(usdc.balanceOf(bob), 100_000e6, "bob earned yield");
    }

    // ─── Test 2: Late depositor gets fair (higher) share price ────────────────

    function test_LateDepositor_FairShareAllocation() public {
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        uint256 aliceShares = vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(90_000e6);

        vm.prank(owner);
        lending.approveBorrower(borrowerA, 90_000e6);

        vm.prank(borrowerA);
        lending.borrow(90_000e6);

        // 1 year passes — simulate interest via reportInterest
        vm.warp(block.timestamp + YEAR);

        uint256 interest = (90_000e6 * BORROW_RATE) / 10_000; // $10,800
        usdc.mint(address(lending), interest);
        vm.prank(address(lending));
        vault.reportInterest(interest);

        uint256 sharePriceNow = vault.sharePrice();
        assertGt(sharePriceNow, 1e6, "share price above 1 after interest");

        // Carol deposits $100K now — gets fewer shares at higher price
        usdc.mint(carol, 100_000e6);
        vm.startPrank(carol);
        usdc.approve(address(vault), 100_000e6);
        uint256 carolShares = vault.deposit(100_000e6, carol);
        vm.stopPrank();

        assertLt(carolShares, aliceShares, "late depositor gets fewer shares at higher price");
    }

    // ─── Test 3: Partial repayment path ───────────────────────────────────────

    function test_PartialRepayment_PrincipalReduces() public {
        usdc.mint(alice, 200_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(180_000e6);

        vm.prank(owner);
        lending.approveBorrower(borrowerA, 100_000e6);

        vm.prank(borrowerA);
        uint256 loanId = lending.borrow(100_000e6);

        vm.warp(block.timestamp + 90 days);

        uint256 halfPrincipal = 50_000e6;
        uint256 interest90d  = (100_000e6 * BORROW_RATE * 90 days) / (YEAR * 10_000);
        uint256 partialRepay = interest90d + halfPrincipal;

        usdc.mint(borrowerA, interest90d);
        vm.startPrank(borrowerA);
        usdc.approve(address(lending), partialRepay);
        lending.repay(loanId, partialRepay);
        vm.stopPrank();

        assertApproxEqAbs(
            lending.getBorrower(borrowerA).principal,
            halfPrincipal,
            1e6,
            "principal halved after partial repay"
        );
    }

    // ─── Test 4: Bad debt (default) scenario ──────────────────────────────────

    function test_BorrowerDefault_VaultAbsorbsLoss() public {
        usdc.mint(alice, 300_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 300_000e6);
        vault.deposit(300_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(270_000e6);

        vm.prank(owner);
        lending.approveBorrower(borrowerA, 100_000e6);

        vm.prank(borrowerA);
        lending.borrow(100_000e6);

        // BorrowerA defaults
        vm.prank(owner);
        lending.declareDefault(borrowerA);

        assertEq(lending.totalPrincipal(), 0);
        assertFalse(lending.getBorrower(borrowerA).isApproved);
        assertTrue(lending.getBorrower(borrowerA).isDefaulted);

        // Protocol continues — Alice can still withdraw up to idle amount
        uint256 redeemable = vault.maxRedeem(alice);
        assertGt(redeemable, 0, "some shares still redeemable (idle portion)");

        vm.prank(alice);
        vault.redeem(redeemable, alice, alice); // succeeds for the idle portion
    }

    // ─── Test 5: Pause/unpause both contracts ─────────────────────────────────

    function test_PauseBothContracts() public {
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(90_000e6);

        vm.prank(owner);
        lending.approveBorrower(borrowerA, 50_000e6);

        // Pause vault
        vm.prank(owner);
        vault.pause();

        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6, bob);
        vm.stopPrank();

        // Pause lending
        vm.prank(owner);
        lending.pause();

        vm.prank(borrowerA);
        vm.expectRevert();
        lending.borrow(1_000e6);

        // Unpause both
        vm.prank(owner);
        vault.unpause();
        vm.prank(owner);
        lending.unpause();

        vm.startPrank(bob);
        vault.deposit(1_000e6, bob);
        vm.stopPrank();

        vm.prank(borrowerA);
        lending.borrow(1_000e6);
    }

    // ─── Test 6: Performance fee mechanics ────────────────────────────────────

    function test_PerformanceFee_CapturesCorrectShare() public {
        vm.prank(owner);
        vault.setPerformanceFee(1_000); // 10%

        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 interest = 10_000e6;
        usdc.mint(address(vault), interest);
        vm.prank(address(lending));
        vault.reportInterest(interest);

        vault.collectFees();

        uint256 feeShares = vault.balanceOf(feeRecip);
        assertGt(feeShares, 0);

        uint256 feeValue = vault.convertToAssets(feeShares);
        assertApproxEqAbs(feeValue, 1_000e6, 100e6, "fee ~$1K (+/-$100 rounding)");
    }

    // ─── Test 7: Vault cap enforcement ────────────────────────────────────────

    function test_VaultCap_BlocksOverDeposit() public {
        vm.prank(owner);
        vault.setVaultCap(50_000e6);

        usdc.mint(alice, 60_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(50_000e6, alice);

        vm.expectRevert();
        vault.deposit(1e6, alice);
        vm.stopPrank();
    }

    // ─── Test 8: Utilization and optimal deploy math ──────────────────────────

    function test_UtilizationAndOptimalDeploy() public {
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        assertEq(vault.optimalDeployAmount(), 90_000e6, "optimal = 90%");

        vm.prank(owner);
        vault.deployToLending(90_000e6);

        assertEq(vault.utilizationBps(), 9_000, "90% = 9000 bps");
        assertEq(vault.optimalDeployAmount(), 0);
    }

    // ─── Test 9: Multiple depositors — proportional yield ─────────────────────

    function test_MultipleDepositors_ProportionalYield() public {
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob,   100_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), vault.balanceOf(bob), "equal shares for equal deposit");

        // Simulate $20K yield arriving directly in the vault as idle USDC.
        // No reportInterest needed — totalAssets() = idle + deployed, and the
        // idle increase alone raises the share price.
        usdc.mint(address(vault), 20_000e6);

        // Use startPrank so maxRedeem + redeem execute atomically per user
        vm.startPrank(alice);
        uint256 aliceOut = vault.redeem(vault.maxRedeem(alice), alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobOut = vault.redeem(vault.maxRedeem(bob), bob, bob);
        vm.stopPrank();

        assertApproxEqAbs(aliceOut, bobOut, 1, "equal lenders get equal payout");
        assertGt(aliceOut, 100_000e6, "both earn yield above principal");
    }
}
