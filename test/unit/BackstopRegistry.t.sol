// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BackstopRegistry} from "../../src/BackstopRegistry.sol";
import {IBackstopRegistry} from "../../src/interfaces/IBackstopRegistry.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

contract BackstopRegistryTest is Test {
    BackstopRegistry registry;
    TestERC20 token;
    address hookStub = makeAddr("hook");
    address searcher = makeAddr("searcher");

    function setUp() public {
        token = new TestERC20(0);
        registry = new BackstopRegistry(address(token), 10e18);
        registry.setHook(hookStub);

        token.mint(searcher, 1_000e18);
        vm.prank(searcher);
        token.approve(address(registry), type(uint256).max);
    }

    function test_setHook_onlyOnceByDeployer() public {
        vm.expectRevert(IBackstopRegistry.HookAlreadySet.selector);
        registry.setHook(makeAddr("other"));

        BackstopRegistry fresh = new BackstopRegistry(address(token), 10e18);
        vm.prank(searcher);
        vm.expectRevert(IBackstopRegistry.NotDeployer.selector);
        fresh.setHook(hookStub);
    }

    function test_deposit_increasesBondAndEligibility() public {
        vm.prank(searcher);
        registry.deposit(20e18);
        assertEq(registry.bond(searcher), 20e18);
        assertTrue(registry.isEligible(searcher));
        assertEq(token.balanceOf(address(registry)), 20e18);
    }

    function test_isEligible_falseBelowMinBond() public {
        vm.prank(searcher);
        registry.deposit(5e18); // below 10e18 min
        assertFalse(registry.isEligible(searcher));
    }

    function test_withdraw_revertsAboveBond() public {
        vm.prank(searcher);
        registry.deposit(20e18);
        vm.prank(searcher);
        vm.expectRevert(IBackstopRegistry.InsufficientBond.selector);
        registry.withdraw(21e18);
    }

    function test_withdraw_neverNegative() public {
        vm.prank(searcher);
        registry.deposit(20e18);
        vm.prank(searcher);
        registry.withdraw(20e18);
        assertEq(registry.bond(searcher), 0);
        vm.prank(searcher);
        vm.expectRevert(IBackstopRegistry.InsufficientBond.selector);
        registry.withdraw(1);
    }

    function test_slash_onlyHook() public {
        vm.prank(searcher);
        registry.deposit(20e18);
        vm.expectRevert(IBackstopRegistry.NotHook.selector);
        registry.slash(searcher, 2000);
    }

    function test_slash_cappedAtCurrentBond_neverGoesNegative() public {
        vm.prank(searcher);
        registry.deposit(20e18);
        vm.prank(hookStub);
        uint256 slashed = registry.slash(searcher, 15_000); // 150% requested
        assertEq(slashed, 20e18); // capped at actual bond
        assertEq(registry.bond(searcher), 0);
        assertEq(token.balanceOf(hookStub), 20e18);
    }

    function test_slash_partialLeavesRemainder() public {
        vm.prank(searcher);
        registry.deposit(100e18);
        vm.prank(hookStub);
        uint256 slashed = registry.slash(searcher, 2000); // 20%
        assertEq(slashed, 20e18);
        assertEq(registry.bond(searcher), 80e18);
    }

    function testFuzz_slash_neverExceedsPriorBond(uint256 depositAmt, uint16 slashBps) public {
        depositAmt = bound(depositAmt, 1, 1_000_000e18);
        token.mint(searcher, depositAmt);
        vm.prank(searcher);
        registry.deposit(depositAmt);

        uint256 before = registry.bond(searcher);
        vm.prank(hookStub);
        uint256 slashed = registry.slash(searcher, slashBps);
        assertLe(slashed, before);
        assertEq(registry.bond(searcher), before - slashed);
    }
}
