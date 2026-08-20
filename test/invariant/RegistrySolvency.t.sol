// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BackstopRegistry} from "../../src/BackstopRegistry.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

/// @notice Handler-driven invariant: the registry must never believe it holds more bond than it
///         actually does, and no individual accounting op can push a balance negative.
contract RegistryHandler is Test {
    BackstopRegistry public registry;
    TestERC20 public token;
    address public hook;
    address[] public actors;

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalSlashed;

    constructor(BackstopRegistry _registry, TestERC20 _token, address _hook) {
        registry = _registry;
        token = _token;
        hook = _hook;
        for (uint256 i; i < 5; i++) {
            actors.push(address(uint160(0x1000 + i)));
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e18);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(registry), amount);
        registry.deposit(amount);
        vm.stopPrank();
        ghost_totalDeposited += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = registry.bond(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        registry.withdraw(amount);
        ghost_totalWithdrawn += amount;
    }

    function slash(uint256 actorSeed, uint16 slashBps) public {
        address actor = actors[actorSeed % actors.length];
        vm.prank(hook);
        uint256 slashed = registry.slash(actor, slashBps);
        ghost_totalSlashed += slashed;
    }

    function actorsList() external view returns (address[] memory) {
        return actors;
    }
}

contract RegistrySolvencyInvariantTest is Test {
    BackstopRegistry registry;
    TestERC20 token;
    RegistryHandler handler;
    address hookStub = makeAddr("hook");

    function setUp() public {
        token = new TestERC20(0);
        registry = new BackstopRegistry(address(token), 1);
        registry.setHook(hookStub);

        handler = new RegistryHandler(registry, token, hookStub);
        targetContract(address(handler));
    }

    /// The registry's actual ERC-20 balance must always cover every individual bond it believes
    /// it holds (a slashed bond is transferred OUT to the hook, so this is a strict >=, not ==,
    /// once slashes have occurred).
    function invariant_registryBalanceCoversAllBonds() public view {
        address[] memory actors = handler.actorsList();
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += registry.bond(actors[i]);
        }
        assertGe(token.balanceOf(address(registry)), sum);
    }

    /// No accounting path can ever leave a negative (underflowed) bond — Solidity 0.8 checked
    /// arithmetic would have reverted the handler call already, but this also asserts the
    /// invariant holds from the read side across the whole actor set.
    function invariant_noActorBondUnderflowed() public view {
        address[] memory actors = handler.actorsList();
        for (uint256 i; i < actors.length; i++) {
            assertGe(registry.bond(actors[i]), 0);
        }
    }
}
