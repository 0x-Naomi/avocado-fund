// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AVOToken} from "../src/AVOToken.sol";
import {TokenVesting} from "../src/TokenVesting.sol";

contract TokenVestingTest is Test {
    AVOToken public avo;
    TokenVesting public vesting;

    address public owner = makeAddr("owner");
    address public founder1 = makeAddr("founder1");
    address public founder2 = makeAddr("founder2");
    address public advisor1 = makeAddr("advisor1");

    uint256 constant FOUNDER_AMOUNT = 60_000_000e18;  // 60M AVO each (120M / 2 founders)
    uint256 constant ADVISOR_AMOUNT = 10_000_000e18;   // 10M AVO
    uint256 constant FOUNDER_CLIFF = 365 days;         // 12 months
    uint256 constant FOUNDER_VEST = 730 days;           // 24 months
    uint256 constant ADVISOR_CLIFF = 180 days;          // 6 months
    uint256 constant ADVISOR_VEST = 540 days;            // 18 months

    uint256 public tge; // TGE timestamp

    function setUp() public {
        tge = block.timestamp;

        vm.startPrank(owner);

        // Deploy AVO
        avo = new AVOToken(owner);
        avo.setMinter(owner);

        // Deploy vesting
        vesting = new TokenVesting(address(avo), owner);

        // Mint tokens to vesting contract (150M for team + advisors)
        avo.mint(address(vesting), 150_000_000e18);

        // Create founder schedules
        vesting.createSchedule(founder1, FOUNDER_AMOUNT, tge, FOUNDER_CLIFF, FOUNDER_VEST, true);
        vesting.createSchedule(founder2, FOUNDER_AMOUNT, tge, FOUNDER_CLIFF, FOUNDER_VEST, true);

        // Create advisor schedule
        vesting.createSchedule(advisor1, ADVISOR_AMOUNT, tge, ADVISOR_CLIFF, ADVISOR_VEST, false);

        vm.stopPrank();
    }

    // ─── Constructor ─────────────────────────────────────────────

    function test_Constructor() public view {
        assertEq(address(vesting.token()), address(avo));
        assertEq(vesting.owner(), owner);
    }

    function test_Constructor_RevertZeroToken() public {
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        new TokenVesting(address(0), owner);
    }

    // ─── Schedule Creation ───────────────────────────────────────

    function test_ScheduleCount() public view {
        assertEq(vesting.scheduleCount(), 3);
    }

    function test_ScheduleDetails() public view {
        (
            address beneficiary,
            uint256 totalAmount,
            uint256 released,
            uint256 start,
            uint256 cliffDuration,
            uint256 vestDuration,
            bool revocable,
            bool revoked
        ) = vesting.schedules(0);

        assertEq(beneficiary, founder1);
        assertEq(totalAmount, FOUNDER_AMOUNT);
        assertEq(released, 0);
        assertEq(start, tge);
        assertEq(cliffDuration, FOUNDER_CLIFF);
        assertEq(vestDuration, FOUNDER_VEST);
        assertTrue(revocable);
        assertFalse(revoked);
    }

    function test_BeneficiaryScheduleIds() public view {
        uint256[] memory ids = vesting.getScheduleIds(founder1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }

    function test_TotalReserved() public view {
        // 60M + 60M + 10M = 130M
        assertEq(vesting.totalReserved(), FOUNDER_AMOUNT * 2 + ADVISOR_AMOUNT);
    }

    function test_CreateSchedule_RevertNotOwner() public {
        vm.prank(founder1);
        vm.expectRevert();
        vesting.createSchedule(founder1, 1000e18, tge, 365 days, 730 days, true);
    }

    function test_CreateSchedule_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        vesting.createSchedule(address(0), 1000e18, tge, 365 days, 730 days, true);
    }

    function test_CreateSchedule_RevertZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TokenVesting.ZeroAmount.selector);
        vesting.createSchedule(founder1, 0, tge, 365 days, 730 days, true);
    }

    function test_CreateSchedule_RevertInsufficientBalance() public {
        // Try to create schedule for more tokens than available
        vm.prank(owner);
        vm.expectRevert(TokenVesting.InsufficientBalance.selector);
        vesting.createSchedule(founder1, 100_000_000e18, tge, 365 days, 730 days, true);
    }

    // ─── Vesting Before Cliff ────────────────────────────────────

    function test_VestedAmount_BeforeCliff_IsZero() public view {
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF - 1), 0);
    }

    function test_Releasable_BeforeCliff_IsZero() public view {
        assertEq(vesting.releasable(0), 0);
    }

    function test_Release_BeforeCliff_Reverts() public {
        vm.warp(tge + FOUNDER_CLIFF - 1);
        vm.expectRevert(TokenVesting.NothingToRelease.selector);
        vesting.release(0);
    }

    // ─── Vesting At Cliff ────────────────────────────────────────

    function test_VestedAmount_AtCliff() public {
        vm.warp(tge + FOUNDER_CLIFF);
        // At cliff exactly: 0 time into vest period, so 0 vested via linear
        // Actually cliff + 0 seconds of vest = 0
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF), 0);
    }

    function test_VestedAmount_JustAfterCliff() public {
        // 1 day after cliff
        uint256 elapsed = 1 days;
        uint256 expected = FOUNDER_AMOUNT * elapsed / FOUNDER_VEST;
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF + elapsed), expected);
    }

    // ─── Vesting During Linear Period ────────────────────────────

    function test_VestedAmount_Halfway() public {
        uint256 halfVest = FOUNDER_VEST / 2;
        uint256 expected = FOUNDER_AMOUNT / 2;
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF + halfVest), expected);
    }

    function test_VestedAmount_FullyVested() public {
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF + FOUNDER_VEST), FOUNDER_AMOUNT);
    }

    function test_VestedAmount_AfterFullVest() public {
        // Way past vest end
        assertEq(vesting.vestedAmount(0, tge + FOUNDER_CLIFF + FOUNDER_VEST + 365 days), FOUNDER_AMOUNT);
    }

    // ─── Release ─────────────────────────────────────────────────

    function test_Release_Founder() public {
        // Warp to halfway through vest
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        uint256 expected = FOUNDER_AMOUNT / 2;

        vesting.release(0);

        assertEq(avo.balanceOf(founder1), expected);
        (,, uint256 released,,,,,) = vesting.schedules(0);
        assertEq(released, expected);
    }

    function test_Release_MultipleClaimsAccumulate() public {
        // First release at 25%
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 4);
        vesting.release(0);
        uint256 first = avo.balanceOf(founder1);
        assertApproxEqRel(first, FOUNDER_AMOUNT / 4, 0.01e18);

        // Second release at 75%
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST * 3 / 4);
        vesting.release(0);
        uint256 total = avo.balanceOf(founder1);
        assertApproxEqRel(total, FOUNDER_AMOUNT * 3 / 4, 0.01e18);
    }

    function test_Release_AfterFullVest() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST + 1);

        vesting.release(0);

        assertEq(avo.balanceOf(founder1), FOUNDER_AMOUNT);
    }

    // ─── Release All ─────────────────────────────────────────────

    function test_ReleaseAll() public {
        // Give founder1 a second schedule
        vm.prank(owner);
        avo.mint(address(vesting), 5_000_000e18);
        vm.prank(owner);
        vesting.createSchedule(founder1, 5_000_000e18, tge, 180 days, 180 days, false);

        // Warp past both cliffs + vests
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST + 1);

        vm.prank(founder1);
        vesting.releaseAll();

        assertEq(avo.balanceOf(founder1), FOUNDER_AMOUNT + 5_000_000e18);
    }

    // ─── Advisor Schedule ────────────────────────────────────────

    function test_AdvisorVesting() public {
        // Advisor: 6mo cliff, 18mo vest
        // At cliff + 9 months (half of vest)
        vm.warp(tge + ADVISOR_CLIFF + ADVISOR_VEST / 2);

        uint256 vested = vesting.vestedAmount(2, block.timestamp);
        assertEq(vested, ADVISOR_AMOUNT / 2);

        vesting.release(2);
        assertEq(avo.balanceOf(advisor1), ADVISOR_AMOUNT / 2);
    }

    // ─── Revoke ──────────────────────────────────────────────────

    function test_Revoke_ReleasesVestedToUser() public {
        // Warp to halfway
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        vm.prank(owner);
        vesting.revoke(0);

        // Founder should get 50% of their allocation
        assertApproxEqRel(avo.balanceOf(founder1), FOUNDER_AMOUNT / 2, 0.01e18);
    }

    function test_Revoke_ReturnsUnvestedToOwner() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        uint256 ownerBefore = avo.balanceOf(owner);
        vm.prank(owner);
        vesting.revoke(0);

        uint256 unvested = FOUNDER_AMOUNT / 2;
        assertApproxEqRel(avo.balanceOf(owner) - ownerBefore, unvested, 0.01e18);
    }

    function test_Revoke_MarksAsRevoked() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        vm.prank(owner);
        vesting.revoke(0);

        (,,,,,,, bool revoked) = vesting.schedules(0);
        assertTrue(revoked);
    }

    function test_Revoke_NoMoreVesting() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        vm.prank(owner);
        vesting.revoke(0);

        // After revoking, vestedAmount stays at released amount
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST); // fully vested time
        assertEq(vesting.releasable(0), 0); // nothing more to claim
    }

    function test_Revoke_RevertIfNotRevocable() public {
        // Schedule 2 (advisor) is not revocable
        vm.prank(owner);
        vm.expectRevert(TokenVesting.NotRevocable.selector);
        vesting.revoke(2);
    }

    function test_Revoke_RevertIfAlreadyRevoked() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST / 2);

        vm.prank(owner);
        vesting.revoke(0);

        vm.prank(owner);
        vm.expectRevert(TokenVesting.AlreadyRevoked.selector);
        vesting.revoke(0);
    }

    function test_Revoke_RevertIfNotOwner() public {
        vm.prank(founder1);
        vm.expectRevert();
        vesting.revoke(0);
    }

    // ─── Total Releasable View ───────────────────────────────────

    function test_TotalReleasable() public {
        vm.warp(tge + FOUNDER_CLIFF + FOUNDER_VEST);

        uint256 total = vesting.totalReleasable(founder1);
        assertEq(total, FOUNDER_AMOUNT);
    }

    // ─── Edge Cases ──────────────────────────────────────────────

    function test_InvalidScheduleId() public {
        vm.expectRevert(TokenVesting.InvalidSchedule.selector);
        vesting.vestedAmount(999, block.timestamp);
    }

    function test_ZeroVestDuration_Reverts() public {
        vm.prank(owner);
        avo.mint(address(vesting), 1000e18);
        vm.prank(owner);
        vm.expectRevert(TokenVesting.InvalidDuration.selector);
        vesting.createSchedule(founder1, 1000e18, tge, 365 days, 0, false);
    }
}
