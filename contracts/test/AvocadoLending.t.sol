// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AvocadoVault} from "../src/AvocadoVault.sol";
import {AvocadoLending} from "../src/AvocadoLending.sol";
import {IAvocadoLending} from "../src/interfaces/IAvocadoLending.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mock USDC ────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ─── Lending Test Suite ───────────────────────────────────────────────────────

contract AvocadoLendingTest is Test {
    MockUSDC       public usdc;
    AvocadoVault   public vault;
    AvocadoLending public lending;

    address public owner     = makeAddr("owner");
    address public feeRecip  = makeAddr("feeRecipient");
    address public borrower  = makeAddr("borrower");
    address public borrower2 = makeAddr("borrower2");
    address public alice     = makeAddr("alice");

    uint256 constant VAULT_CAP    = 4_000_000e6;
    uint256 constant BORROW_RATE  = 1_200;       // 12% APR
    uint256 constant CREDIT_LIMIT = 100_000e6;   // $100K
    uint256 constant VAULT_SEED   = 500_000e6;   // $500K seeded in vault
    uint256 constant DEPLOY_AMT   = 200_000e6;   // $200K deployed to lending

    function setUp() public {
        vm.startPrank(owner);
        usdc    = new MockUSDC();
        vault   = new AvocadoVault(address(usdc), owner, feeRecip, VAULT_CAP);
        lending = new AvocadoLending(address(vault), address(usdc), owner, BORROW_RATE);
        vault.setLendingContract(address(lending));
        vm.stopPrank();

        usdc.mint(alice, VAULT_SEED);
        vm.startPrank(alice);
        usdc.approve(address(vault), VAULT_SEED);
        vault.deposit(VAULT_SEED, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(DEPLOY_AMT);

        vm.prank(owner);
        lending.approveBorrower(borrower, CREDIT_LIMIT);
    }

    // ─── Access control ───────────────────────────────────────────────────────

    function test_ApproveBorrower() public view {
        IAvocadoLending.Borrower memory b = lending.getBorrower(borrower);
        assertTrue(b.isApproved);
        assertEq(b.creditLimit, CREDIT_LIMIT);
    }

    function test_ApproveBorrowerOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        lending.approveBorrower(borrower2, 50_000e6);
    }

    function test_ApproveBorrowerZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        lending.approveBorrower(address(0), 50_000e6);
    }

    function test_ApproveBorrowerAlreadyApprovedReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        lending.approveBorrower(borrower, 50_000e6);
    }

    function test_RevokeBorrower() public {
        vm.prank(owner);
        lending.revokeBorrower(borrower);
        assertFalse(lending.getBorrower(borrower).isApproved);
    }

    function test_RevokedBorrowerCannotBorrow() public {
        vm.prank(owner);
        lending.revokeBorrower(borrower);

        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(1_000e6);
    }

    function test_SetCreditLimit() public {
        vm.prank(owner);
        lending.setCreditLimit(borrower, 200_000e6);
        assertEq(lending.getBorrower(borrower).creditLimit, 200_000e6);
    }

    function test_SetCreditLimitUnapprovedReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        lending.setCreditLimit(borrower2, 50_000e6);
    }

    function test_SetBorrowRate() public {
        vm.prank(owner);
        lending.setBorrowRate(800);
        assertEq(lending.borrowRateBps(), 800);
    }

    function test_SetBorrowRateTooHighReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        lending.setBorrowRate(5_001);
    }

    function test_SetBorrowRateOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        lending.setBorrowRate(800);
    }

    // ─── Borrow ───────────────────────────────────────────────────────────────

    function test_Borrow_Basic() public {
        uint256 amount = 30_000e6;
        vm.prank(borrower);
        uint256 loanId = lending.borrow(amount);

        assertEq(loanId, 0);
        assertEq(usdc.balanceOf(borrower), amount);
        assertEq(lending.totalPrincipal(), amount);
        assertEq(lending.getBorrower(borrower).principal, amount);
    }

    function test_Borrow_UnapprovedReverts() public {
        vm.prank(borrower2);
        vm.expectRevert();
        lending.borrow(1_000e6);
    }

    function test_Borrow_ZeroAmountReverts() public {
        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(0);
    }

    function test_Borrow_ExceedsCreditLimitReverts() public {
        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(CREDIT_LIMIT + 1);
    }

    function test_Borrow_UpToLimitThenReverts() public {
        vm.prank(borrower);
        lending.borrow(CREDIT_LIMIT);

        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(1e6);
    }

    function test_Borrow_PausedReverts() public {
        vm.prank(owner);
        lending.pause();

        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(1_000e6);
    }

    function test_Borrow_DefaultedBorrowerReverts() public {
        vm.prank(borrower);
        lending.borrow(10_000e6);

        vm.prank(owner);
        lending.declareDefault(borrower);

        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(1_000e6);
    }

    function test_Borrow_MultipleLoanIds() public {
        vm.startPrank(borrower);
        uint256 id0 = lending.borrow(10_000e6);
        uint256 id1 = lending.borrow(5_000e6);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(lending.getBorrower(borrower).principal, 15_000e6);
    }

    // ─── Repay ────────────────────────────────────────────────────────────────

    function test_Repay_Basic() public {
        uint256 borrowAmt = 30_000e6;
        vm.prank(borrower);
        uint256 loanId = lending.borrow(borrowAmt);

        vm.warp(block.timestamp + 30 days);

        uint256 interest = (borrowAmt * BORROW_RATE * 30 days) / (365 days * 10_000);
        uint256 repayAmt = borrowAmt + interest;

        uint256 spBefore = vault.sharePrice();

        usdc.mint(borrower, interest);
        vm.startPrank(borrower);
        usdc.approve(address(lending), repayAmt);
        lending.repay(loanId, repayAmt);
        vm.stopPrank();

        assertEq(lending.getBorrower(borrower).principal, 0);
        assertGt(vault.sharePrice(), spBefore, "share price increased");
    }

    function test_Repay_ZeroAmountReverts() public {
        vm.prank(borrower);
        lending.borrow(10_000e6);

        vm.prank(borrower);
        vm.expectRevert();
        lending.repay(0, 0);
    }

    function test_Repay_AlreadyRepaidReverts() public {
        vm.prank(borrower);
        uint256 loanId = lending.borrow(10_000e6);

        usdc.mint(borrower, 500e6);
        vm.startPrank(borrower);
        usdc.approve(address(lending), 10_500e6);
        lending.repay(loanId, 10_500e6); // full repay
        vm.expectRevert();
        lending.repay(loanId, 1e6);      // already repaid
        vm.stopPrank();
    }

    function test_Repay_LoanNotFoundReverts() public {
        vm.prank(borrower);
        lending.borrow(10_000e6);

        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(lending), 100e6);
        vm.expectRevert();
        lending.repay(99, 100e6);
        vm.stopPrank();
    }

    function test_Repay_PartialInterestOnly() public {
        uint256 borrowAmt = 50_000e6;
        vm.prank(borrower);
        uint256 loanId = lending.borrow(borrowAmt);

        vm.warp(block.timestamp + 365 days);

        uint256 halfInterest = (borrowAmt * BORROW_RATE) / (10_000 * 2);

        usdc.mint(borrower, halfInterest);
        vm.startPrank(borrower);
        usdc.approve(address(lending), halfInterest);
        lending.repay(loanId, halfInterest);
        vm.stopPrank();

        // Principal unchanged after partial interest-only payment
        assertEq(lending.getBorrower(borrower).principal, borrowAmt);
    }

    function test_RepayAll() public {
        vm.startPrank(borrower);
        lending.borrow(20_000e6);
        lending.borrow(10_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 180 days);

        uint256 principal = 30_000e6;
        uint256 interest = (principal * BORROW_RATE * 180 days) / (365 days * 10_000);
        uint256 buffer   = 1e6;

        usdc.mint(borrower, interest + buffer);
        vm.startPrank(borrower);
        usdc.approve(address(lending), principal + interest + buffer);
        lending.repayAll();
        vm.stopPrank();

        assertEq(lending.getBorrower(borrower).principal, 0);
        assertTrue(lending.getLoan(borrower, 0).repaid);
        assertTrue(lending.getLoan(borrower, 1).repaid);
    }

    function test_RepayAll_NoDebt_IsNoop() public {
        vm.prank(borrower);
        lending.repayAll(); // no revert
        assertEq(lending.getBorrower(borrower).principal, 0);
    }

    // ─── Interest accrual ─────────────────────────────────────────────────────

    function test_InterestAccrual_1Year_12pct() public {
        uint256 principal = 100_000e6;
        vm.prank(borrower);
        lending.borrow(principal);

        vm.warp(block.timestamp + 365 days);

        (uint256 p, uint256 i) = lending.borrowerDebt(borrower);
        assertEq(p, principal);

        uint256 expectedInterest = (principal * BORROW_RATE) / 10_000; // 12K
        assertApproxEqAbs(i, expectedInterest, 1e4, "~12% APR after 1 year");
    }

    function test_InterestAccrual_SharePriceRisesAfterRepay() public {
        uint256 principal = 50_000e6;
        vm.prank(borrower);
        lending.borrow(principal);

        vm.warp(block.timestamp + 365 days);

        uint256 interest  = (principal * BORROW_RATE) / 10_000;
        uint256 totalOwed = principal + interest;

        uint256 spBefore = vault.sharePrice();

        usdc.mint(borrower, interest);
        vm.startPrank(borrower);
        usdc.approve(address(lending), totalOwed);
        lending.repayAll();
        vm.stopPrank();

        assertGt(vault.sharePrice(), spBefore);
    }

    function test_AccrueAllInterest_MultipleBorrowers() public {
        // Approve and seed borrower2
        vm.prank(owner);
        lending.approveBorrower(borrower2, CREDIT_LIMIT);

        vm.prank(borrower);
        lending.borrow(50_000e6);

        vm.prank(borrower2);
        lending.borrow(30_000e6);

        vm.warp(block.timestamp + 90 days);

        uint256 totalInterest = lending.accrueAllInterest();
        assertGt(totalInterest, 0, "should accrue interest across both borrowers");
    }

    function test_TotalOutstandingDebt_IncludesInterest() public {
        uint256 amount = 100_000e6;
        vm.prank(borrower);
        lending.borrow(amount);

        vm.warp(block.timestamp + 365 days);

        uint256 debt = lending.totalOutstandingDebt();
        assertGt(debt, amount);
    }

    // ─── Default & bad debt ───────────────────────────────────────────────────

    function test_DeclareDefault() public {
        uint256 amount = 40_000e6;
        vm.prank(borrower);
        lending.borrow(amount);

        vm.prank(owner);
        lending.declareDefault(borrower);

        IAvocadoLending.Borrower memory b = lending.getBorrower(borrower);
        assertTrue(b.isDefaulted);
        assertFalse(b.isApproved);
        assertEq(lending.totalPrincipal(), 0);
    }

    function test_DeclareDefaultOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        lending.declareDefault(borrower);
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        lending.pause();
    }

    function test_Unpause_RestoresBorrowing() public {
        vm.prank(owner);
        lending.pause();

        vm.prank(borrower);
        vm.expectRevert();
        lending.borrow(1_000e6);

        vm.prank(owner);
        lending.unpause();

        vm.prank(borrower);
        lending.borrow(1_000e6); // succeeds
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function test_GetLoan() public {
        vm.prank(borrower);
        lending.borrow(15_000e6);

        IAvocadoLending.LoanTerms memory loan = lending.getLoan(borrower, 0);
        assertEq(loan.amount, 15_000e6);
        assertEq(loan.interestRateBps, BORROW_RATE);
        assertFalse(loan.repaid);
    }

    function test_GetBorrowerLoans_Length() public {
        vm.startPrank(borrower);
        lending.borrow(10_000e6);
        lending.borrow(20_000e6);
        vm.stopPrank();

        assertEq(lending.getBorrowerLoans(borrower).length, 2);
    }

    function test_BorrowerListUpdated() public {
        vm.prank(owner);
        lending.approveBorrower(borrower2, 50_000e6);

        address[] memory list = lending.getBorrowerList();
        assertEq(list.length, 2);
        assertEq(list[0], borrower);
        assertEq(list[1], borrower2);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_BorrowRepayFull(uint256 borrowAmt) public {
        borrowAmt = bound(borrowAmt, 1e6, CREDIT_LIMIT);

        vm.prank(borrower);
        uint256 loanId = lending.borrow(borrowAmt);

        uint256 elapsed = 90 days;
        vm.warp(block.timestamp + elapsed);

        uint256 interest = (borrowAmt * BORROW_RATE * elapsed) / (365 days * 10_000);
        uint256 totalOwed = borrowAmt + interest + 1;

        usdc.mint(borrower, interest + 1);
        vm.startPrank(borrower);
        usdc.approve(address(lending), totalOwed);
        lending.repay(loanId, totalOwed);
        vm.stopPrank();

        assertEq(lending.getBorrower(borrower).principal, 0);
    }

    function testFuzz_InterestMatchesFormula(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 10 * 365 days);

        uint256 principal = 50_000e6;
        vm.prank(borrower);
        lending.borrow(principal);

        vm.warp(block.timestamp + elapsed);

        (, uint256 interest) = lending.borrowerDebt(borrower);
        uint256 expected = (principal * BORROW_RATE * elapsed) / (365 days * 10_000);
        assertApproxEqAbs(interest, expected, 1e6);
    }
}
