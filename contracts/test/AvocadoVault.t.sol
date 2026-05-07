// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {AvocadoVault} from "../src/AvocadoVault.sol";
import {AvocadoLending} from "../src/AvocadoLending.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Mock USDC ────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Test suite ───────────────────────────────────────────────────────────────

contract AvocadoVaultTest is Test {
    // Contracts
    MockUSDC    public usdc;
    AvocadoVault public vault;
    AvocadoLending public lending;

    // Actors
    address public owner    = makeAddr("owner");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");
    address public carol    = makeAddr("carol");
    address public feeRecip = makeAddr("feeRecipient");
    address public borrower = makeAddr("borrower");

    // Config
    uint256 constant VAULT_CAP    = 4_000_000e6;   // $4M
    uint256 constant BORROW_RATE  = 1_200;          // 12% APR
    uint256 constant ALICE_USDC   = 100_000e6;      // $100K
    uint256 constant BOB_USDC     = 50_000e6;       // $50K

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy Vault
        vault = new AvocadoVault(
            address(usdc),
            owner,
            feeRecip,
            VAULT_CAP
        );

        // Deploy Lending
        lending = new AvocadoLending(
            address(vault),
            address(usdc),
            owner,
            BORROW_RATE
        );

        // Wire vault → lending
        vault.setLendingContract(address(lending));

        vm.stopPrank();

        // Fund test users
        usdc.mint(alice, ALICE_USDC);
        usdc.mint(bob, BOB_USDC);
    }

    // ─── Basic ERC4626 ────────────────────────────────────────────────────────

    function test_VaultMetadata() public view {
        assertEq(vault.name(), "Avocado USDC");
        assertEq(vault.symbol(), "avUSDC");
        assertEq(vault.decimals(), 12);
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.vaultCap(), VAULT_CAP);
    }

    function test_Deposit() public {
        uint256 amount = 10_000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 assetsBefore = vault.totalAssets();

        uint256 shares = vault.deposit(amount, alice);

        assertGt(shares, 0, "should mint shares");
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalAssets(), assetsBefore + amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
        vm.stopPrank();
    }

    function test_DepositAndWithdraw() public {
        uint256 amount = 10_000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Withdraw half
        uint256 half = amount / 2;
        vault.withdraw(half, alice, alice);

        assertEq(usdc.balanceOf(alice), ALICE_USDC - amount + half);
        vm.stopPrank();
    }

    function test_Redeem() public {
        uint256 amount = 20_000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(redeemed, amount, 1, "redeem should return deposited amount");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
        vm.stopPrank();
    }

    function test_MultipleDepositors() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), ALICE_USDC);
        vault.deposit(ALICE_USDC, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), BOB_USDC);
        vault.deposit(BOB_USDC, bob);
        vm.stopPrank();

        assertEq(vault.totalAssets(), ALICE_USDC + BOB_USDC);
        assertGt(vault.balanceOf(alice), vault.balanceOf(bob), "alice has more shares");
    }

    // ─── Vault cap ────────────────────────────────────────────────────────────

    function test_DepositRevertsAboveCap() public {
        uint256 overCap = VAULT_CAP + 1;
        usdc.mint(alice, overCap);

        vm.startPrank(alice);
        usdc.approve(address(vault), overCap);
        vm.expectRevert();
        vault.deposit(overCap, alice);
        vm.stopPrank();
    }

    function test_MaxDepositRespectsVaultCap() public {
        uint256 maxDep = vault.maxDeposit(alice);
        assertEq(maxDep, VAULT_CAP);

        // Deposit 1M
        usdc.mint(alice, VAULT_CAP);
        vm.startPrank(alice);
        usdc.approve(address(vault), VAULT_CAP);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        assertEq(vault.maxDeposit(alice), VAULT_CAP - 1_000_000e6);
    }

    function test_SetVaultCap() public {
        uint256 newCap = 8_000_000e6;
        vm.prank(owner);
        vault.setVaultCap(newCap);
        assertEq(vault.vaultCap(), newCap);
    }

    function test_SetVaultCapOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setVaultCap(1_000_000e6);
    }

    // ─── Capital deployment ───────────────────────────────────────────────────

    function test_DeployToLending() public {
        uint256 deposit = 50_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        uint256 deployAmount = 40_000e6;
        vm.prank(owner);
        vault.deployToLending(deployAmount);

        assertEq(vault.deployedAssets(), deployAmount);
        assertEq(usdc.balanceOf(address(lending)), deployAmount);
        assertEq(usdc.balanceOf(address(vault)), deposit - deployAmount);
        // Total assets unchanged
        assertEq(vault.totalAssets(), deposit);
    }

    function test_OptimalDeployAmount() public {
        uint256 deposit = 100_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        // targetIdleRatio = 1000 bps = 10%
        // optimalDeploy = 100K * 90% = 90K
        uint256 optimal = vault.optimalDeployAmount();
        assertEq(optimal, 90_000e6);
    }

    // ─── Share price / interest accrual ───────────────────────────────────────

    function test_SharePriceIncreasesAfterInterest() public {
        uint256 deposit = 100_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        uint256 sharePriceBefore = vault.sharePrice();

        // Simulate interest reported from lending
        usdc.mint(address(lending), 5_000e6);
        vm.prank(address(lending));
        vault.reportInterest(5_000e6);

        uint256 sharePriceAfter = vault.sharePrice();
        assertGt(sharePriceAfter, sharePriceBefore, "share price should increase after interest");
        // AVT-04M: reportInterest now adds only fee-free portion to deployedAssets
        // Default perf fee is 10% (launch config): 10% of 5_000e6 = 500e6 fee, net = 4_500e6
        uint256 netInterest = 5_000e6 - (5_000e6 * 1_000 / 10_000);
        assertEq(vault.totalAssets(), deposit + netInterest);
    }

    function test_ReportInterestOnlyFromLending() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.reportInterest(1000e6);
    }

    // ─── Fees ─────────────────────────────────────────────────────────────────

    function test_CollectFees() public {
        uint256 deposit = 100_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        // Report 10K interest
        uint256 interest = 10_000e6;
        vm.prank(address(lending));
        vault.reportInterest(interest);

        // Collect fees (default 10% of 10K interest = 1_000 USDC worth of shares)
        uint256 feeRecipSharesBefore = vault.balanceOf(feeRecip);
        // AVT-03M: collectFees now requires owner or feeRecipient
        vm.prank(owner);
        vault.collectFees();

        assertGt(vault.balanceOf(feeRecip), feeRecipSharesBefore, "fee recipient got shares");
        assertEq(vault.accruedInterest(), 0, "accrued interest reset");
    }

    function test_SetPerformanceFee() public {
        vm.prank(owner);
        vault.setPerformanceFee(1_000); // 10%
        assertEq(vault.performanceFeeBps(), 1_000);
    }

    function test_SetPerformanceFeeAboveMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.setPerformanceFee(2_001); // > 20% max
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

    function test_PausePreventsDeposit() public {
        vm.prank(owner);
        vault.pause();

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert();
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_UnpauseRestoresDeposit() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();

        assertEq(vault.maxDeposit(alice), VAULT_CAP);
    }

    // ─── Utilization ──────────────────────────────────────────────────────────

    function test_UtilizationBps() public {
        uint256 deposit = 100_000e6;
        vm.startPrank(alice);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.deployToLending(80_000e6);

        // 80K / 100K = 8000 bps = 80%
        assertEq(vault.utilizationBps(), 8_000);
    }

    // ─── Fuzz tests ───────────────────────────────────────────────────────────

    /// @dev Fuzzes deposit amounts and verifies shares are proportional
    function testFuzz_DepositShares(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, VAULT_CAP);
        usdc.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // First depositor: shares == assets * 1e6 (due to _decimalsOffset=6)
        assertEq(shares, depositAmount * 1e6, "first depositor gets 1e6:1 shares with offset");
        assertEq(vault.totalAssets(), depositAmount);
    }

    /// @dev Verifies no rounding issues on deposit → redeem cycle
    function testFuzz_DepositRedeem(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, VAULT_CAP);
        usdc.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // Allow 1 unit rounding loss
        assertApproxEqAbs(redeemed, depositAmount, 1, "redeem should return ~full amount");
    }
}
