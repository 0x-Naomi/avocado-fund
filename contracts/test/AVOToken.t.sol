// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AVOToken} from "../src/AVOToken.sol";

contract AVOTokenTest is Test {
    AVOToken public avo;
    address public owner = makeAddr("owner");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.prank(owner);
        avo = new AVOToken(owner);
    }

    // ─── Constructor ─────────────────────────────────────────────

    function test_Name() public view {
        assertEq(avo.name(), "Avocado Token");
    }

    function test_Symbol() public view {
        assertEq(avo.symbol(), "AVO");
    }

    function test_Decimals() public view {
        assertEq(avo.decimals(), 18);
    }

    function test_MaxSupply() public view {
        assertEq(avo.MAX_SUPPLY(), 1_000_000_000e18);
    }

    function test_InitialSupplyIsZero() public view {
        assertEq(avo.totalSupply(), 0);
    }

    function test_OwnerIsSet() public view {
        assertEq(avo.owner(), owner);
    }

    function test_MinterIsOwnerInitially() public view {
        // New launch pattern: constructor initialises minter = owner.
        assertEq(avo.minter(), owner);
    }

    // ─── setMinter ───────────────────────────────────────────────

    function test_SetMinter() public {
        vm.prank(owner);
        avo.setMinter(minter);
        assertEq(avo.minter(), minter);
    }

    function test_SetMinter_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        avo.setMinter(minter);
    }

    function test_SetMinter_RevertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AVOToken.ZeroAddress.selector);
        avo.setMinter(address(0));
    }

    function test_SetMinter_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        // Previous minter is the owner (set in constructor), new minter is `minter`.
        emit AVOToken.MinterUpdated(owner, minter);
        avo.setMinter(minter);
    }

    function test_Constructor_EmitsInitialMinterEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AVOToken.MinterUpdated(address(0), owner);
        new AVOToken(owner);
    }

    function test_Constructor_RevertIfZeroOwner() public {
        vm.expectRevert();
        new AVOToken(address(0));
    }

    function test_OwnerCanMintWithoutSetMinter() public {
        // Owner is the default minter, so they can mint straight after deploy.
        vm.prank(owner);
        avo.mint(alice, 500e18);
        assertEq(avo.balanceOf(alice), 500e18);
    }

    // ─── Minting ─────────────────────────────────────────────────

    function test_Mint() public {
        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(minter);
        avo.mint(alice, 1000e18);

        assertEq(avo.balanceOf(alice), 1000e18);
        assertEq(avo.totalSupply(), 1000e18);
    }

    function test_Mint_RevertIfNotMinter() public {
        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(alice);
        vm.expectRevert(AVOToken.OnlyMinter.selector);
        avo.mint(alice, 1000e18);
    }

    function test_Mint_RevertIfExceedsMaxSupply() public {
        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(minter);
        vm.expectRevert(AVOToken.ExceedsMaxSupply.selector);
        avo.mint(alice, 1_000_000_001e18);
    }

    function test_Mint_ExactlyMaxSupply() public {
        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(minter);
        avo.mint(alice, 1_000_000_000e18);
        assertEq(avo.totalSupply(), 1_000_000_000e18);

        // One more wei should fail
        vm.prank(minter);
        vm.expectRevert(AVOToken.ExceedsMaxSupply.selector);
        avo.mint(alice, 1);
    }

    // ─── Transfer ────────────────────────────────────────────────

    function test_Transfer() public {
        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(minter);
        avo.mint(alice, 1000e18);

        vm.prank(alice);
        avo.transfer(bob, 400e18);

        assertEq(avo.balanceOf(alice), 600e18);
        assertEq(avo.balanceOf(bob), 400e18);
    }

    // ─── Fuzz ────────────────────────────────────────────────────

    function testFuzz_Mint(uint256 amount) public {
        amount = bound(amount, 0, 1_000_000_000e18);

        vm.prank(owner);
        avo.setMinter(minter);

        vm.prank(minter);
        avo.mint(alice, amount);

        assertEq(avo.balanceOf(alice), amount);
    }
}
