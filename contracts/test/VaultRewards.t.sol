// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AVOToken} from "../src/AVOToken.sol";
import {VaultRewards} from "../src/VaultRewards.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock for avUSDC (6 decimals like USDC)
contract MockAvUSDC is ERC20 {
    constructor() ERC20("Avocado Vault USDC", "avUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract VaultRewardsTest is Test {
    AVOToken public avo;
    MockAvUSDC public avUsdc;
    VaultRewards public rewards;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant BASE_EMISSION = 1_585_489_599_188_229; // ~1.585e15, ~50M/yr
    uint256 constant SCALE_FACTOR = 1_000_000e6; // $1M avUSDC

    function setUp() public {
        // Deploy
        vm.startPrank(owner);
        avo = new AVOToken(owner);
        avUsdc = new MockAvUSDC();
        rewards = new VaultRewards(
            address(avo),
            address(avUsdc),
            owner,
            BASE_EMISSION,
            SCALE_FACTOR
        );
        avo.setMinter(address(rewards));
        vm.stopPrank();

        // Fund users
        avUsdc.mint(alice, 10_000e6);
        avUsdc.mint(bob, 10_000e6);

        // Approve
        vm.prank(alice);
        avUsdc.approve(address(rewards), type(uint256).max);
        vm.prank(bob);
        avUsdc.approve(address(rewards), type(uint256).max);
    }

    // ─── Constructor ─────────────────────────────────────────────

    function test_Constructor() public view {
        assertEq(address(rewards.avoToken()), address(avo));
        assertEq(address(rewards.stakeToken()), address(avUsdc));
        assertEq(rewards.baseEmissionPerSecond(), BASE_EMISSION);
        assertEq(rewards.scaleFactor(), SCALE_FACTOR);
        assertEq(rewards.totalStaked(), 0);
    }

    // ─── Deposit ─────────────────────────────────────────────────

    function test_Deposit() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        assertEq(rewards.totalStaked(), 1000e6);
        (uint256 amount,) = rewards.userInfo(alice);
        assertEq(amount, 1000e6);
        assertEq(avUsdc.balanceOf(address(rewards)), 1000e6);
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(VaultRewards.ZeroAmount.selector);
        rewards.deposit(0);
    }

    function test_Deposit_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit VaultRewards.Deposit(alice, 1000e6);
        rewards.deposit(1000e6);
    }

    // ─── Withdraw ────────────────────────────────────────────────

    function test_Withdraw() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.prank(alice);
        rewards.withdraw(500e6);

        assertEq(rewards.totalStaked(), 500e6);
        (uint256 amount,) = rewards.userInfo(alice);
        assertEq(amount, 500e6);
    }

    function test_Withdraw_RevertInsufficientStake() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.prank(alice);
        vm.expectRevert(VaultRewards.InsufficientStake.selector);
        rewards.withdraw(1001e6);
    }

    function test_Withdraw_Full() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.prank(alice);
        rewards.withdraw(1000e6);

        assertEq(rewards.totalStaked(), 0);
        assertEq(avUsdc.balanceOf(alice), 10_000e6); // got all back
    }

    // ─── Rewards Accrual ─────────────────────────────────────────

    function test_PendingRewardsIncrease() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        uint256 pending = rewards.pendingRewards(alice);
        assertGt(pending, 0);
    }

    function test_PendingRewardsZeroIfNotStaked() public view {
        uint256 pending = rewards.pendingRewards(alice);
        assertEq(pending, 0);
    }

    function test_Claim() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.warp(block.timestamp + 1 hours);

        uint256 pendingBefore = rewards.pendingRewards(alice);
        assertGt(pendingBefore, 0);

        vm.prank(alice);
        rewards.claim();

        uint256 avoBal = avo.balanceOf(alice);
        assertGt(avoBal, 0);
        // After claim, pending should be ~0
        assertLt(rewards.pendingRewards(alice), 1e12); // dust tolerance
    }

    // ─── Dynamic Emission ────────────────────────────────────────

    function test_EffectiveEmission_AtZeroTVL() public view {
        // At 0 TVL, effective = base
        assertEq(rewards.effectiveEmissionPerSecond(), BASE_EMISSION);
    }

    function test_EffectiveEmission_AtScaleFactor() public {
        // Deposit exactly scaleFactor amount
        avUsdc.mint(alice, SCALE_FACTOR);
        vm.prank(alice);
        avUsdc.approve(address(rewards), type(uint256).max);
        vm.prank(alice);
        rewards.deposit(SCALE_FACTOR);

        // Should be base / 2
        uint256 effective = rewards.effectiveEmissionPerSecond();
        assertEq(effective, BASE_EMISSION / 2);
    }

    function test_EffectiveEmission_DecreasesWithTVL() public {
        vm.prank(alice);
        rewards.deposit(100e6);
        uint256 rate1 = rewards.effectiveEmissionPerSecond();

        vm.prank(bob);
        rewards.deposit(5000e6);
        uint256 rate2 = rewards.effectiveEmissionPerSecond();

        assertGt(rate1, rate2); // more TVL = lower rate
    }

    // ─── Two stakers share rewards ───────────────────────────────

    function test_TwoStakers_FairShare() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.prank(bob);
        rewards.deposit(1000e6);

        vm.warp(block.timestamp + 1 hours);

        uint256 pendingAlice = rewards.pendingRewards(alice);
        uint256 pendingBob = rewards.pendingRewards(bob);

        // Both staked same amount at same time — should be roughly equal
        // Alice has slight advantage (staked first, earned sole rewards briefly)
        assertGt(pendingAlice, pendingBob * 95 / 100);
        assertLt(pendingAlice, pendingBob * 110 / 100);
    }

    // ─── Emergency Withdraw ──────────────────────────────────────

    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(alice);
        rewards.emergencyWithdraw();

        assertEq(avUsdc.balanceOf(alice), 10_000e6); // got tokens back
        assertEq(avo.balanceOf(alice), 0); // no rewards claimed
        assertEq(rewards.totalStaked(), 0);
    }

    // ─── Admin ───────────────────────────────────────────────────

    function test_SetEmissionParams() public {
        vm.prank(owner);
        rewards.setEmissionParams(2e15, 500_000e6);

        assertEq(rewards.baseEmissionPerSecond(), 2e15);
        assertEq(rewards.scaleFactor(), 500_000e6);
    }

    function test_SetEmissionParams_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        rewards.setEmissionParams(2e15, 500_000e6);
    }

    function test_Pause() public {
        vm.prank(owner);
        rewards.pause();

        vm.prank(alice);
        vm.expectRevert();
        rewards.deposit(100e6);
    }

    function test_Unpause() public {
        vm.prank(owner);
        rewards.pause();

        vm.prank(owner);
        rewards.unpause();

        vm.prank(alice);
        rewards.deposit(100e6);
        assertEq(rewards.totalStaked(), 100e6);
    }

    // ─── Withdraw still works when paused ────────────────────────

    function test_WithdrawWhenPaused() public {
        vm.prank(alice);
        rewards.deposit(1000e6);

        vm.prank(owner);
        rewards.pause();

        // Withdraw should still work
        vm.prank(alice);
        rewards.withdraw(1000e6);
        assertEq(avUsdc.balanceOf(alice), 10_000e6);
    }
}
